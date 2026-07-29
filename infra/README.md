# Infrastructure Services

Per-service infrastructure configurations. Each subfolder contains the Dockerfile and any configuration/personalization files for that infrastructure component.

## Convention

```
infra/
├── <service-name>/
│   ├── Dockerfile
│   └── <config files>
```

Example: an Envoy proxy would live at `infra/envoy/` with its Dockerfile and config templates.
