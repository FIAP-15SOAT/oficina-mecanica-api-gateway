# ADR 0005: Integração privada por serviço e tabela de donos das rotas

## Status

Aceito — 2026-10-25

Substitui o [ADR 0003](0003-integracao-privada-com-o-eks.md) na parte de **roteamento**: o caminho de rede (VPC Link V2, NLB interno no `oficina-mecanica-infra-k8s`, NodePort) continua o mesmo; muda quantos listeners existem e como cada rota escolhe o seu. Revisa o [ADR 0002](0002-contrato-do-gateway-em-openapi.md) (fim do catch-all) e o [ADR 0004](0004-autenticacao-permanece-nos-backends.md) (vários backends e o webhook).

## Contexto

A solução deixou de ter uma única API no EKS. São quatro serviços (work-order, identity, billing e inventory), cada um com um listener próprio no NLB interno: `80`, `8081`, `8082` e `8083`. O `oficina-mecanica-infra-k8s` publica os mapas `service_listener_arns` e `service_listener_ports`, indexados pelo contexto.

Três exigências da arquitetura da solução:

1. **Cada rota pública tem um único serviço dono.** Os recursos vão migrar do work-order para os serviços novos aos poucos, e cada migração precisa ser uma troca pequena, revisável e reversível.
2. **Nenhum caminho `/internal` pode ser alcançável pela internet.** Os serviços expõem `/internal/...`, fora do prefixo `/api`, para chamadas entre eles, sem autenticação de usuário. Com mais de um serviço, `ANY /api/{proxy+}` não sabe escolher o dono, e um catch-all na raiz (`/{proxy+}`) alcançaria `/internal/...`. A garantia precisa estar na borda, não na disciplina de cada serviço.
3. **O webhook do Mercado Pago precisa da requisição original.** A assinatura `x-signature` é calculada sobre o `x-request-id` e o `data.id` da query string enviados pelo Mercado Pago, e a integração atual sobrescreve o `x-request-id` com o id da borda.

## Decisão

### Rotas por prefixo, rotas exatas e nada além

- Cada recurso público é publicado por `ANY /api/<recurso>` e `ANY /api/<recurso>/{proxy+}`.
- Uma rota aninhada cujo dono pode diferir do dono do prefixo vira **rota exata** (por exemplo, `GET /api/work-orders/{id}/quotes`), que o HTTP API prefere à gulosa do prefixo.
- Ficam fixas no work-order as rotas de saúde e de documentação usadas hoje (`/api/health/*`, `/api/docs*`); cada serviço ganha `GET /health/<contexto>` e `GET /docs/<contexto>`, mapeadas para `/api/health/ready` e `/api/docs-json` do serviço.
- **Sem catch-all**: nem `/api/{proxy+}` nem `/{proxy+}`. Caminho fora das rotas declaradas recebe `404` da borda. Uma guarda no CI reprova o contrato que declarar `/internal`, `/api/{proxy+}` ou `/{proxy+}`.

### Tabela `route_owner` e uma integração por grupo

`terraform/locals.tf` declara `route_owner`, o mapa de **grupo de rotas** para **contexto dono**, começando com todos os grupos no work-order. O documento OpenAPI tem uma integração por grupo, cujo destino vem da tabela:

```yaml
users:
  type: http_proxy
  connectionType: VPC_LINK
  uri: '${service_listener_arns[route_owner["users"]]}'
```

As rotas referenciam a integração do grupo por um `$ref` fixo. Trocar o dono de um grupo é trocar uma entrada da tabela, e o diff do PR mostra exatamente o que virou. Um dono que não é chave de `service_listener_arns`, ou um grupo ausente da tabela, quebra o `templatefile` no `plan` com `Invalid index`, antes de publicar.

### Webhook com integração própria

`POST /webhooks/mercadopago` usa a integração `webhook-billing`, que aponta para o listener do billing e sobrescreve **só o caminho**: a query string e o `x-request-id` chegam intactos. A rota tem limite de frequência próprio (`10/20`). A autenticação dessa rota é a verificação HMAC da `x-signature` no billing.

### Saída do VPC Link por porta

O security group do VPC Link troca o egress inline por uma `aws_vpc_security_group_egress_rule` por chave de `service_listener_ports`, só TCP e só para a CIDR da VPC. Um serviço novo publicado nos mapas ganha a regra de saída sem mudança neste repositório e pode virar dono de um grupo trocando só o `route_owner`; as rotas e integrações de saúde e de documentação dele são acrescentadas no contrato.

## Alternativas consideradas e descartadas

### Uma integração por serviço, com `route_owner` dentro do `$ref`

Quatro integrações (`work-order`, `identity`, `billing`, `inventory`) e as rotas escolhendo a integração por `$ref: '#/components/x-amazon-apigateway-integrations/${route_owner["users"]}'`. Menos blocos no documento, mas o lint do CI lê o documento **cru**, e um `$ref` montado pelo template não é resolvido (`no-unresolved-refs`). Manter o lint exigiria renderizar o template no CI com valores fictícios, ou desligar a verificação de `$ref`. Além disso, um dono inválido só falharia no `apply`, no import da API. A integração por grupo custa ~16 blocos repetidos no YAML e mantém o lint e a falha no `plan`.

### Um documento OpenAPI por backend

Vários `aws_apigatewayv2_api`, ou um merge de documentos no Terraform, para o mesmo efeito com mais peças: mais de uma URL pública, ou uma etapa de merge sem lint próprio.

### Rotas como recursos Terraform

`aws_apigatewayv2_route` e `aws_apigatewayv2_integration` no lugar do `body`, com o `route_owner` num `for_each`. Abandonaria o contrato versionado e o lint do [ADR 0002](0002-contrato-do-gateway-em-openapi.md); com ~44 rotas, o `plan` também deixaria de ser legível.

### Manter um catch-all e confiar nos serviços

`ANY /api/{proxy+}` leva tudo a um único serviço, então a migração de um recurso exigiria rotas explícitas de qualquer forma; um catch-all na raiz alcançaria `/internal/...`. A garantia de que `/internal` não é roteado precisa estar na borda.

### Roteamento por path dentro do cluster (Ingress)

Um proxy L7 no cluster atrás de um único listener. Descartado no `oficina-mecanica-infra-k8s` (ADR 0009 de lá): o HTTP API já roteia por path e método na borda, e um Ingress Controller exige componentes extras no cluster de 2 nós.

## Consequências

**Positivas**

- A migração de um recurso entre serviços é uma linha em `route_owner` mais a tabela de donos da documentação.
- `/internal` e catch-all ficam fora da borda por construção e por guarda no CI.
- O webhook recebe a requisição que o Mercado Pago assinou.
- Saúde e documentação de cada serviço são alcançáveis pela borda, e a verificação externa usa `GET /health/<contexto>`.

**Negativas e aceitas**

- **Um endpoint novo fora de um prefixo publicado não responde.** É intencional; `docs/openapi.md` explica como publicar um prefixo.
- **Rotas de um serviço ainda não implantado respondem erro de integração.** Só as rotas de saúde e de documentação dele apontam para ele até a migração.
- **Correlação do webhook sem o `requestId` da borda.** A junção usa rota, instante e o id da order registrado pelo billing.
- **Rota exata esquecida numa migração.** A tabela de donos lista as rotas exatas de cada prefixo; a collection Postman roda depois de cada migração.
- **O documento OpenAPI fica mais longo**, com uma integração por grupo.

## Gatilho de revisão

- **Voltar a uma integração por serviço:** o lint do CI passar a renderizar o template, tornando resolvível um `$ref` montado pela tabela.
- **Dividir o documento:** os blocos por grupo passarem a variar entre si (mappings diferentes por serviço), em vez de só o destino.

## Referências

- [Rotas de HTTP APIs e precedência](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-routes.html)
- [Integrações privadas de HTTP API com VPC Links](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-private.html)
- [Parameter mapping em HTTP APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-parameter-mapping.html)
- [Notificações do Mercado Pago e validação da `x-signature`](https://www.mercadopago.com.br/developers/pt/docs/your-integrations/notifications/webhooks)
- [`docs/openapi.md`](../openapi.md) — a tabela de donos e o passo a passo da migração.
- [`oficina-mecanica-infra-k8s`](https://github.com/FIAP-15SOAT/oficina-mecanica-infra-k8s) — os listeners por serviço e os mapas consumidos aqui.
