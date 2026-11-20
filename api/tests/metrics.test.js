// Tests des métriques Prometheus : format, labels de route, erreurs, logs.
import request from 'supertest';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { createMetrics } from '../src/metrics.js';
import { createMemoryRepository } from '../src/repositories/memory.js';

function buildApp({
  repository = createMemoryRepository(),
  log = vi.fn(),
} = {}) {
  // collectDefaults: false : seulement nos métriques, sortie lisible et rapide
  const metrics = createMetrics({
    appVersion: '1.2.3',
    collectDefaults: false,
  });
  return createApp({
    repository,
    appEnv: 'test',
    appVersion: '1.2.3',
    log,
    metrics,
  });
}

async function readMetrics(app) {
  const response = await request(app).get('/metrics');
  return response.text;
}

describe('GET /metrics', () => {
  let app;
  let log;

  beforeEach(() => {
    log = vi.fn();
    app = buildApp({ log });
  });

  it('répond 200 au format texte de Prometheus', async () => {
    const response = await request(app).get('/metrics');

    expect(response.status).toBe(200);
    expect(response.headers['content-type']).toMatch(/^text\/plain/);
    expect(response.text).toContain('taskflow_build_info{version="1.2.3"} 1');
  });

  it('utilise la route Express comme label, jamais l’URL réelle', async () => {
    await request(app).post('/api/tasks').send({ title: 'Mesurer' });
    await request(app).patch('/api/tasks/1/toggle');

    const text = await readMetrics(app);

    expect(text).toContain('route="/api/tasks"');
    expect(text).toContain('route="/api/tasks/:id/toggle"');
    expect(text).not.toContain('/api/tasks/1');
    expect(text).toContain('taskflow_tasks_created_total 1');
  });

  it('compte une URL inconnue sous « unmatched »', async () => {
    await request(app).get('/nexiste/pas');

    const text = await readMetrics(app);

    expect(text).toMatch(
      /http_requests_total\{[^}]*route="unmatched"[^}]*status_code="404"/,
    );
    expect(text).not.toContain('/nexiste/pas');
  });

  it('compte les réponses 500', async () => {
    const repository = createMemoryRepository();
    repository.list = () => Promise.reject(new Error('base injoignable'));
    const failingApp = buildApp({ repository });

    await request(failingApp).get('/api/tasks');

    const text = await readMetrics(failingApp);
    expect(text).toMatch(
      /http_requests_total\{[^}]*route="\/api\/tasks"[^}]*status_code="500"\} 1/,
    );
  });

  it('n’écrit pas de log et ne se compte pas lui-même', async () => {
    await request(app).get('/metrics');
    const text = await readMetrics(app);

    expect(log).not.toHaveBeenCalled();
    expect(text).not.toContain('route="/metrics"');
  });
});
