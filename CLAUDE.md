**IMPORTANT**: The host machine may run multiple projects with different Kubernetes clusters simultaneously. To prevent conflicts:

### Shell Scripts
- **NEVER** use bare `kubectl` commands that rely on the current context
- **ALWAYS** use explicit `--context` flag: `kubectl --context minikube ...`
