# The AI repo's portail deploy (BAO_TOKEN): its own secret, nothing else.
# renew-self / lookup-self come from the default policy.
path "infra/data/portail" { capabilities = ["read"] }
