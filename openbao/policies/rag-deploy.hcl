# The RAG repo's deploy (BAO_TOKEN): its own secret, nothing else.
# renew-self / lookup-self come from the default policy.
path "infra/data/rag" { capabilities = ["read"] }
