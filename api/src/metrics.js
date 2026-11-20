// Métriques Prometheus de l'API (méthode RED : Rate, Errors, Duration).
// Chaque appel crée SON registre : les tests construisent une application
// neuve à chaque fois, le registre global de prom-client refuserait de
// réenregistrer les mêmes métriques.
import client from 'prom-client';

// Secondes : de 5 ms (requête en mémoire) à 5 s (base qui rame).
const DURATION_BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5];

// Route Express (/api/tasks/:id/toggle), jamais l'URL réelle (/api/tasks/42/toggle) :
// un label par identifiant ferait exploser le nombre de séries (cardinalité).
function toRouteLabel(baseUrl, path) {
  const route = `${baseUrl}${path}`;
  return route.length > 1 ? route.replace(/\/$/, '') : route;
}

// Express remet req.baseUrl à '' en sortant d'un routeur : une erreur traitée
// plus loin (500 du gestionnaire d'erreurs) perdrait le préfixe /api/tasks.
// On note donc la route complète au moment où Express la choisit.
function trackRoute(req) {
  let matched = null;
  let route;
  Object.defineProperty(req, 'route', {
    configurable: true,
    enumerable: true,
    get: () => route,
    set: (value) => {
      route = value;
      if (value) matched = toRouteLabel(req.baseUrl, value.path);
    },
  });
  // Aucune route trouvée (404) : un seul label pour toutes les URL inconnues.
  return () => matched ?? 'unmatched';
}

export function createMetrics({
  appVersion = 'dev',
  collectDefaults = true,
} = {}) {
  const register = new client.Registry();
  const registers = [register];

  if (collectDefaults) client.collectDefaultMetrics({ register });

  const labelNames = ['method', 'route', 'status_code'];

  const requestsTotal = new client.Counter({
    name: 'http_requests_total',
    help: 'Nombre de requêtes HTTP traitées',
    labelNames,
    registers,
  });

  const requestDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'Durée des requêtes HTTP en secondes',
    labelNames,
    buckets: DURATION_BUCKETS,
    registers,
  });

  const tasksCreated = new client.Counter({
    name: 'taskflow_tasks_created_total',
    help: 'Nombre de tâches créées',
    registers,
  });

  // Toujours à 1 : sert à afficher la version en ligne dans Grafana.
  const buildInfo = new client.Gauge({
    name: 'taskflow_build_info',
    help: "Version de l'API en cours d'exécution",
    labelNames: ['version'],
    registers,
  });
  buildInfo.set({ version: appVersion }, 1);

  function middleware(req, res, next) {
    const stopTimer = requestDuration.startTimer();
    const routeLabel = trackRoute(req);
    // Labels calculés à la fin : la route n'est connue qu'après le routage.
    res.on('finish', () => {
      const labels = {
        method: req.method,
        route: routeLabel(),
        status_code: String(res.statusCode),
      };
      requestsTotal.inc(labels);
      stopTimer(labels);
    });
    next();
  }

  async function handler(_req, res) {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  }

  return {
    register,
    middleware,
    handler,
    taskCreated: () => tasksCreated.inc(),
  };
}
