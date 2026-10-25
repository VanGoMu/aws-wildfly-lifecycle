// Traffic for the local environment: a constant arrival rate against the production listener of
// the ALB (nginx), which says in X-Wfl-Color which color answered. handleSummary writes the share,
// the version and the 5XX of each color to RESULT.txt and RESULT.json. local/run.sh load and the
// Observe step of a canary run it with DURATION, RATE, APP_PORT and RESULT.
import http from 'k6/http';
import { Counter } from 'k6/metrics';

const COLORS = ['blue', 'green'];
const RATE = Number(__ENV.RATE || 20);
const DURATION = __ENV.DURATION || '60s';
const TARGET = 'http://alb/version';

const responses = new Counter('responses');
const errors = new Counter('errors_5xx');

// A tagged submetric reaches the summary only if a threshold names it; these always pass.
const thresholds = {};
for (const color of COLORS) {
  thresholds[`responses{color:${color}}`] = ['count>=0'];
  thresholds[`errors_5xx{color:${color}}`] = ['count>=0'];
}

export const options = {
  scenarios: {
    traffic: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: 20,
      maxVUs: 100,
    },
  },
  thresholds,
};

// What each color answers before the traffic starts, so the summary tells versions, not only
// colors. A release that lands on a color during the test is not reflected here.
export function setup() {
  const versions = {};
  for (const color of COLORS) {
    const res = http.get(`http://${color}:${__ENV.APP_PORT || 8080}/version`, { timeout: '5s' });
    versions[color] = res.status === 200 ? res.body.trim() : 'no answer';
  }
  return { versions, start: new Date().toISOString() };
}

export default function () {
  const res = http.get(TARGET, { timeout: '5s' });
  const color = res.headers['X-Wfl-Color'] || 'none';
  responses.add(1, { color });
  // Status 0 is a request that got no response at all.
  if (res.status >= 500 || res.status === 0) {
    errors.add(1, { color });
  }
}

export function handleSummary(data) {
  const count = (name) => (data.metrics[name] ? data.metrics[name].values.count : 0);
  const total = count('responses');
  const latency = data.metrics.http_req_duration.values;
  const result = {
    target: TARGET,
    rate: RATE,
    duration: DURATION,
    start: data.setup_data.start,
    requests: total,
    p95Ms: Number(latency['p(95)'].toFixed(1)),
    maxMs: Number(latency.max.toFixed(1)),
    colors: {},
  };
  for (const color of COLORS) {
    const n = count(`responses{color:${color}}`);
    result.colors[color] = {
      version: data.setup_data.versions[color],
      responses: n,
      sharePercent: total ? Number(((100 * n) / total).toFixed(1)) : 0,
      errors5xx: count(`errors_5xx{color:${color}}`),
    };
  }

  const rows = COLORS.map((color) => {
    const c = result.colors[color];
    return `${color.padEnd(7)}${c.version.padEnd(24)}${String(c.responses).padStart(9)}`
      + `${c.sharePercent.toFixed(1).padStart(8)} %${String(c.errors5xx).padStart(7)}`;
  });
  const text = [
    `Load test · ${result.start}`,
    `${TARGET} · ${RATE} req/s · ${DURATION} · ${total} requests`
      + ` · p95 ${result.p95Ms} ms · max ${result.maxMs} ms`,
    '',
    `${'color'.padEnd(7)}${'version'.padEnd(24)}${'responses'.padStart(9)}`
      + `${'share'.padStart(10)}${'5XX'.padStart(7)}`,
    ...rows,
    '',
  ].join('\n');

  const out = { stdout: text };
  if (__ENV.RESULT) {
    out[`${__ENV.RESULT}.txt`] = text;
    out[`${__ENV.RESULT}.json`] = `${JSON.stringify(result, null, 2)}\n`;
  }
  return out;
}
