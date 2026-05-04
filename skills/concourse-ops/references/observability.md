# Observability: metrics, tracing, CCTray

Concourse exposes metrics, distributed traces, and a CCTray feed for external monitoring.

## Prometheus

```properties
# web node
CONCOURSE_PROMETHEUS_BIND_IP=0.0.0.0
CONCOURSE_PROMETHEUS_BIND_PORT=9090
```

Metrics exposed at `http://<web>:9090/metrics`. Scrape with Prometheus; visualize in Grafana.

Key metrics:

| Metric | What it tells you |
|--------|------------------|
| `concourse_builds_running` | Current in-flight builds |
| `concourse_builds_failed_total` | Builds that failed (counter) |
| `concourse_jobs_scheduling` | Jobs waiting to be scheduled |
| `concourse_lidar_check_queue_size` | Checks waiting to run |
| `concourse_lidar_checks_started_total` | Checks dispatched |
| `concourse_containers_per_worker` | Container load per worker |
| `concourse_volumes_per_worker` | Volume load per worker |
| `concourse_locks_held` | DB locks held (type: Batch, DatabaseMigration) |
| `concourse_tasks_wait_duration` | Time tasks wait before execution |

## Datadog

```properties
CONCOURSE_DATADOG_AGENT_HOST=datadog-agent.monitoring.svc.cluster.local
CONCOURSE_DATADOG_AGENT_PORT=8125
CONCOURSE_DATADOG_PREFIX=concourse.
```

Metrics are sent as DogStatsD UDP. Tag with `CONCOURSE_DATADOG_TAGS=env:prod,cluster:ci`.

## New Relic

```properties
CONCOURSE_NEWRELIC_ACCOUNT_ID=12345678
CONCOURSE_NEWRELIC_API_KEY=NRAK-xxxxxxxxxxxx
CONCOURSE_NEWRELIC_SERVICE_PREFIX=concourse
```

Sends via New Relic Insights API.

## InfluxDB

```properties
CONCOURSE_INFLUXDB_URL=http://influxdb:8086
CONCOURSE_INFLUXDB_DATABASE=concourse
CONCOURSE_INFLUXDB_USERNAME=concourse
CONCOURSE_INFLUXDB_PASSWORD=secret
CONCOURSE_INFLUXDB_INSECURE_SKIP_VERIFY=false
```

## Tracing

Concourse supports distributed tracing via OpenTelemetry-compatible backends.

### Jaeger

```properties
CONCOURSE_TRACING_JAEGER_ENDPOINT=http://jaeger:14268/api/traces
# optional: service name
CONCOURSE_TRACING_SERVICE_NAME=concourse
```

### OpenTelemetry Protocol (OTLP)

```properties
CONCOURSE_TRACING_OTLP_ADDRESS=ingest.lightstep.com:443
CONCOURSE_TRACING_OTLP_HEADERS=lightstep-access-token:my-token
```

Works with any OTLP-compatible backend (Honeycomb, Lightstep, Grafana Tempo, etc.).

### Google Cloud Trace (Stackdriver)

```properties
CONCOURSE_TRACING_STACKDRIVER_PROJECTID=my-gcp-project
```

Uses Application Default Credentials. Run the web node on GCE / GKE with Workload Identity or a service account JSON.

### What gets traced

Concourse traces the full lifecycle of a build: scheduler dispatch, step execution, resource checks. Each build appears as a trace with spans per step.

## CCTray / cc.xml

Concourse exposes a CCTray-compatible feed for CI dashboard tools (CCMenu, nocicd, etc.):

```
GET https://ci.example.com/cc.xml?access_token=<token>
```

Filter by team:
```
GET https://ci.example.com/cc.xml?team=my-team&access_token=<token>
```

`access_token` is a fly-generated token (from `fly login`, stored in `~/.flyrc`). The feed shows last build status per job.

## Build log retention

```properties
# Max number of builds per job to keep logs for (default: no limit)
CONCOURSE_BUILD_LOG_RETENTION_MINIMUM_SUCCEEDED=5
CONCOURSE_BUILD_LOG_RETENTION_DEFAULT=50

# Per-pipeline override via pipeline YAML:
# jobs:
#   - name: my-job
#     build_log_retention:
#       minimum_succeeded_builds: 5
#       days: 30
#       builds: 100
```

`fly watch -j pipeline/job -b N` streams the log for build N. Historical logs are available via the UI or API until GC removes them.

## Gotchas

- Prometheus endpoint has no auth. Bind to a non-public interface or put it behind a firewall/proxy.
- Datadog uses UDP; no delivery guarantee. Missing metrics under high load is normal.
- CCTray access_token expires with the fly session. Use a service account token for long-lived dashboard tools.
- Tracing adds overhead. Use `CONCOURSE_TRACING_SAMPLE_FRACTION=0.1` to sample 10% of traces.

## See also

- `references/perf-tuning.md` — metrics to track during tuning
- `references/debugging-stuck.md` — `fly watch`, `fly intercept` for live debugging
