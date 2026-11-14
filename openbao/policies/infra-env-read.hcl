# Deploy tokens of the app repos (AI's portail): read infra/env, nothing else.
path "infra/data/env" { capabilities = ["read"] }
# Lets the deploy job renew its own periodic token on each run.
path "auth/token/renew-self" { capabilities = ["update"] }
