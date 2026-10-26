# 📜 Contrato OpenAPI

Como a superfície pública é declarada, quem atende cada rota, o que **não** está no documento e o passo a passo para mexer nela.

## Índice

- [A estratégia em uma frase](#a-estratégia-em-uma-frase)
- [O que vive em cada artefato](#o-que-vive-em-cada-artefato)
- [Por que não há schemas aqui](#por-que-não-há-schemas-aqui)
- [Tabela de donos das rotas](#tabela-de-donos-das-rotas)
- [Como publicar um prefixo](#como-publicar-um-prefixo)
- [Como virar o dono de um prefixo](#como-virar-o-dono-de-um-prefixo)
- [Onde altero um limite de frequência?](#onde-altero-um-limite-de-frequência)
- [As integrações, por extenso](#as-integrações-por-extenso)
- [Como o documento é validado](#como-o-documento-é-validado)

## A estratégia em uma frase

**Este repositório é fonte da verdade da superfície de roteamento, não dos contratos de payload.**

O Gateway diz *onde as coisas entram e para qual serviço vão*. Sobre *o que as coisas contêm* ele não tem nada a acrescentar e, sob HTTP API, nem poderia.

Cada recurso público é publicado por **prefixo** (`ANY /api/<recurso>` e `ANY /api/<recurso>/{proxy+}`) e tem **um único serviço dono**, declarado na tabela `route_owner` de `terraform/locals.tf`. Rota aninhada cujo dono pode diferir do dono do prefixo vira **rota exata**. Não existe catch-all: caminho fora das rotas declaradas recebe `404` da borda, e nenhum caminho `/internal` é publicado.

`openapi/gateway.yaml` é um OpenAPI 3.0 válido, versionado, renderizado por `templatefile()` para o argumento `body` de `aws_apigatewayv2_api`, com `fail_on_warnings = true`.

## O que vive em cada artefato

Esta é a tabela que responde "onde eu mexo?" sem tentativa e erro:

| Precisa alterar | Onde | Arquivo |
|---|---|---|
| Uma rota (path, método, grupo) | **documento OpenAPI** | `openapi/gateway.yaml` |
| Um parameter mapping de integração | **documento OpenAPI** | `openapi/gateway.yaml` |
| O serviço dono de um grupo de rotas | **Terraform** | `terraform/locals.tf` (`route_owner`) |
| Um limite de frequência | **Terraform** | `terraform/api_gateway.tf` (`route_settings`) + `terraform/variables.tf` |
| Formato ou retenção do log de acesso | **Terraform** | `terraform/api_gateway.tf` (`access_log_settings`) + `terraform/cloudwatch.tf` |
| Métricas detalhadas por rota | **Terraform** | `terraform/api_gateway.tf` |
| Nome da API, tags, metadados | **Terraform** | `terraform/api_gateway.tf` + `terraform/locals.tf` |
| VPC Link, subnets, security group | **Terraform** | `terraform/api_gateway.tf`, `terraform/security_groups.tf` |
| Listener e porta de cada serviço | **`oficina-mecanica-infra-k8s`** | mapas `service_listener_arns` e `service_listener_ports` |
| CORS, se um dia voltar a existir | **Terraform**, **nunca** o YAML | `terraform/api_gateway.tf` |

> **Por que CORS nunca no YAML.** Com `body` definido e `cors_configuration` ausente no HCL, o provider chama `DeleteCorsConfiguration` logo após o import, no create **e** no update. Um `x-amazon-apigateway-cors` declarado no documento seria apagado, e o `apply` terminaria **verde**. Hoje não há CORS por decisão (não há consumidor de navegador); se voltar, vai no HCL.

## Por que não há schemas aqui

O documento **não** declara `requestBody`, `components.schemas`, códigos de erro de negócio ou regras de autorização. Três motivos, e o primeiro basta:

1. **Sob HTTP API, schemas são ignorados no import.** Declará-los produziria documentação que *parece* contrato e não é.
2. **Os contratos já existem.** Cada serviço publica o próprio documento OpenAPI (`/api/docs-json`, alcançável pela borda em `GET /docs/<contexto>`); a função serverless tem um contrato normativo em `docs/contracts.md`. Repetir aqui criaria a segunda cópia que envelhece em silêncio.
3. **Um endpoint novo sob um prefixo publicado não exige PR aqui.** O prefixo cobre todos os subcaminhos; só um prefixo novo ou uma rota exata mudam o contrato.

**As fontes da verdade, referenciadas por link e nunca copiadas:**

| Backend | Contrato de payload |
|---|---|
| Work Order | [`docs/api.md`](https://github.com/FIAP-15SOAT/oficina-mecanica-work-order-service/blob/main/docs/api.md) e `GET /docs/work-order` |
| Identity | `GET /docs/identity` ([repositório](https://github.com/FIAP-15SOAT/oficina-mecanica-identity-service)) |
| Billing | `GET /docs/billing` ([repositório](https://github.com/FIAP-15SOAT/oficina-mecanica-billing-service)) |
| Inventory | `GET /docs/inventory` ([repositório](https://github.com/FIAP-15SOAT/oficina-mecanica-inventory-service)) |
| Função serverless | [`docs/contracts.md`](https://github.com/FIAP-15SOAT/oficina-mecanica-lambda-customer-auth/blob/main/docs/contracts.md) |

**"Sem schemas" não significa "sem estrutura".** O documento continua sendo um OpenAPI 3.0 **válido**: cada operação declara um `responses` mínimo (`default` com `description`) e todo path com variável declara o `parameters` correspondente com `required: true`. Sem eles o documento é inválido segundo a especificação, o que reprova o lint e pode virar warning no import, que `fail_on_warnings = true` transforma em falha de `apply`.

## Tabela de donos das rotas

Cada grupo usa a integração de mesmo nome em `openapi/gateway.yaml`, cujo destino é o listener do dono no NLB interno. Os listeners vêm do `oficina-mecanica-infra-k8s`: `work-order` na porta `80`, `identity` na `8081`, `billing` na `8082` e `inventory` na `8083`.

| Grupo (`route_owner`) | Rotas | Dono atual | Listener | Observação | Swagger |
|---|---|---|---|---|---|
| `auth` | `POST /api/auth/login`, `ANY /api/auth/{proxy+}` | work-order | 80 | O login tem rota própria pelo limite de frequência | `GET /docs/work-order` |
| `users` | `ANY /api/users`, `ANY /api/users/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `users-customers` | `GET /api/users/{userId}/customers` | work-order | 80 | Rota exata: o vínculo usuário-cliente fica no work-order quando `users` for para o identity | `GET /docs/work-order` |
| `me` | `GET /api/me` | work-order | 80 | Rota exata: o perfil vai para o identity, a área do cliente não | `GET /docs/work-order` |
| `me-password` | `PATCH /api/me/password` | work-order | 80 | Rota exata, mesmo motivo de `me` | `GET /docs/work-order` |
| `me-area` | `ANY /api/me/work-orders`, `ANY /api/me/work-orders/{proxy+}`, `ANY /api/me/quotes/{proxy+}` | work-order | 80 | Área do cliente | `GET /docs/work-order` |
| `customers` | `ANY /api/customers`, `ANY /api/customers/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `vehicles` | `ANY /api/vehicles`, `ANY /api/vehicles/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `work-orders` | `ANY /api/work-orders`, `ANY /api/work-orders/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `work-orders-quotes` | `GET /api/work-orders/{id}/quotes` | work-order | 80 | Rota exata: segue o dono dos orçamentos, não o das ordens | `GET /docs/work-order` |
| `services` | `ANY /api/services`, `ANY /api/services/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `services-metrics` | `GET /api/services-metrics`, `GET /api/services/{id}/metrics` | work-order | 80 | Rotas exatas: as métricas de execução ficam no work-order quando `services` for para o inventory | `GET /docs/work-order` |
| `parts-supplies` | `ANY /api/parts-supplies`, `ANY /api/parts-supplies/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `stock` | `GET /api/stock-movements`, `GET /api/stock-reservations` | work-order | 80 | Só leitura | `GET /docs/work-order` |
| `quotes` | `ANY /api/quotes`, `ANY /api/quotes/{proxy+}` | work-order | 80 | | `GET /docs/work-order` |
| `payments` | `ANY /api/payments`, `ANY /api/payments/{proxy+}` | work-order | 80 | Sem endpoint atendido ainda | `GET /docs/work-order` |

**Rotas fora da tabela**, com destino fixo:

| Rotas | Integração | Destino | Observação |
|---|---|---|---|
| `GET /api/health/live`, `GET /api/health/ready`, `ANY /api/docs`, `ANY /api/docs/{proxy+}`, `GET /api/docs-json` | `work-order` | work-order (80) | Mantidas para a collection Postman e o sintético atuais |
| `GET /health/<contexto>` | `health-<contexto>` | listener do contexto | Mapeada para `/api/health/ready` do serviço |
| `GET /docs/<contexto>` | `docs-<contexto>` | listener do contexto | Mapeada para `/api/docs-json` do serviço |
| `POST /webhooks/mercadopago` | `webhook-billing` | billing (8082) | Preserva query string e `x-request-id`; limite de frequência próprio |
| `POST /customer-auth/login` | `lambda` | função serverless | Limite de frequência de login |

`<contexto>` é `work-order`, `identity`, `billing` ou `inventory`. Enquanto um serviço não está implantado, as rotas que apontam para ele respondem erro de integração, por desenho.

**Precedência.** O HTTP API escolhe primeiro a rota que casa por completo (método e caminho), depois a rota com variável gulosa (`{proxy+}`) e, entre rotas do mesmo nível, o método declarado antes de `ANY`. Por isso `GET /api/services/{id}/metrics` vence `ANY /api/services/{proxy+}`, enquanto `DELETE` ou `OPTIONS` em `/api/users/{userId}/customers` seguem a rota do prefixo `users`, porque a rota exata publica só o `GET`: nas rotas exatas aninhadas, os demais métodos chegam ao dono do prefixo pai. Já nas rotas exatas sem prefixo guloso acima (`/api/me`, `/api/me/password`, `/api/services-metrics`, `/api/stock-*`), no webhook, nas rotas por serviço e na rota da função, outro método, inclusive `OPTIONS`, recebe `404` da borda. Nos prefixos, `OPTIONS` chega ao serviço dono.

## Como publicar um prefixo

Um endpoint novo **sob um prefixo já publicado** não exige nada aqui: a rota `{proxy+}` do prefixo já o cobre. Um **prefixo novo** exige:

1. Acrescentar a chave em `route_owner` (`terraform/locals.tf`), com o serviço dono como valor.
2. Acrescentar em `openapi/gateway.yaml` as duas rotas do prefixo (`/api/<recurso>` e `/api/<recurso>/{proxy+}`, com `x-amazon-apigateway-any-method`), cada operação com `responses.default.description`, o `parameters` do `proxy` e o `$ref` para a integração do grupo:
   ```yaml
   x-amazon-apigateway-integration:
     $ref: "#/components/x-amazon-apigateway-integrations/<grupo>"
   ```
3. Acrescentar a integração do grupo em `components.x-amazon-apigateway-integrations`, copiando uma das existentes e trocando a chave em `uri: '${service_listener_arns[route_owner["<grupo>"]]}'`.
4. Se a rota precisa de limite de frequência próprio, acrescentar um bloco `route_settings` em `terraform/api_gateway.tf` com a **chave exata** da rota (`"POST /caminho"`), **repetindo `detailed_metrics_enabled = true`**.
5. Atualizar a [tabela de donos](#tabela-de-donos-das-rotas) no mesmo PR.
6. Validar localmente (comandos em [Como o documento é validado](#como-o-documento-é-validado)).

Um caminho sob `/internal`, uma rota gulosa na raiz ou logo sob `/api`, ou `$default` **nunca** entra no contrato: a guarda do CI reprova o PR.

## Como virar o dono de um prefixo

1. Trocar o valor da chave em `route_owner` (por exemplo, `"services" = "inventory"`). O valor precisa ser uma chave de `service_listener_arns`; um valor desconhecido quebra o `terraform plan` com `Invalid index`.
2. Conferir na tabela de donos as **rotas exatas** ligadas ao prefixo e decidir, uma a uma, se viram junto (cada uma tem a própria chave).
3. Atualizar a tabela de donos no mesmo PR.
4. Depois do `apply`, rodar a collection Postman e `GET /health/<contexto>` do novo dono.

O diff do PR mostra exatamente o que virou: uma linha por grupo, e nenhuma rota de outro grupo muda.

## Onde altero um limite de frequência?

No **Terraform**, nunca no YAML: o documento OpenAPI não tem representação para throttling.

- **Padrão de todas as rotas**: `default_route_settings` em `terraform/api_gateway.tf`, alimentado por `stage_throttling_rate_limit` e `stage_throttling_burst_limit`.
- **Rotas de login**: os dois blocos `route_settings` de login, alimentados por `login_throttling_rate_limit` e `login_throttling_burst_limit`.
- **Webhook do Mercado Pago**: o bloco `route_settings` de `POST /webhooks/mercadopago`, alimentado por `webhook_throttling_rate_limit` e `webhook_throttling_burst_limit`.

> ⚠️ **Cada bloco de `route_settings` precisa repetir `detailed_metrics_enabled = true`.** O provider envia `false` para todo campo omitido dentro do bloco: omitir desligaria as métricas exatamente nas rotas que mais importam.

E a ressalva que precisa acompanhar qualquer conversa sobre esses números: **é um alvo agregado por rota, de melhor esforço**, não uma cota por cliente. Ver [security.md](security.md).

## As integrações, por extenso

Declaradas uma única vez em `components.x-amazon-apigateway-integrations` e referenciadas por `$ref`, construção suportada **apenas** em HTTP APIs.

| Integração | Quantas | `uri` | `requestParameters` |
|---|---|---|---|
| `<grupo>` (uma por chave de `route_owner`) | 16 | `service_listener_arns[route_owner["<grupo>"]]` | `overwrite:path = $request.path`, `overwrite:header.x-request-id = $context.requestId` |
| `work-order` | 1 | `service_listener_arns["work-order"]` | igual às de grupo |
| `health-<contexto>` | 4 | `service_listener_arns["<contexto>"]` | `overwrite:path = /api/health/ready`, `overwrite:header.x-request-id` |
| `docs-<contexto>` | 4 | `service_listener_arns["<contexto>"]` | `overwrite:path = /api/docs-json`, `overwrite:header.x-request-id` |
| `webhook-billing` | 1 | `service_listener_arns["billing"]` | só `overwrite:path = $request.path` |
| `lambda` | 1 | URI de invocação da função | `overwrite:header.x-request-id` |

Todas as integrações de serviço são `http_proxy`, `httpMethod: ANY`, `payloadFormatVersion: "1.0"` e `connectionType: VPC_LINK`, pelo mesmo VPC Link. A `lambda` é `aws_proxy`, `POST`, `payloadFormatVersion: "2.0"`.

**Por que uma integração por grupo, e não uma por serviço.** O `route_owner` entra no `uri` da integração do grupo, e as rotas referenciam a integração por um `$ref` fixo. Assim o lint resolve todos os `$ref` lendo o documento cru, e um dono inválido quebra o `plan`. Um `$ref` montado pelo template (`.../${route_owner["users"]}`) não seria resolvido pelo lint.

**Sobre o `payloadFormatVersion`, que gera dúvida:**

- As integrações de serviço usam `1.0` porque é o **único valor aceito** por integrações que não são Lambda. Declarar `2.0` ali **não** dá erro: a AWS descarta o valor em silêncio.
- A `lambda` usa `2.0` porque a função é tipada para `APIGatewayProxyEventV2` e lê `event.requestContext.http.method`, que só existe nesse formato.
- **Não existe default aplicado no import.** Omitir o campo deixa a integração com ele vazio; para a Lambda isso significaria o envelope errado. Por isso ele é declarado explicitamente em todas.

**Sobre os parameter mappings, que não são opcionais:**

- `overwrite:path = $request.path`: a integração privada **inclui a porção de stage** no caminho enviado ao backend, e a AWS prescreve esse mapeamento para removê-la. O backend recebe `/api/customers`, não `/$default/api/customers`. Nas integrações de saúde e de documentação o caminho é fixo (`/api/health/ready` e `/api/docs-json`).
- `overwrite:header.x-request-id = $context.requestId`: em todas, **menos no webhook**. Os serviços aceitam os caracteres de base64 usados pelo Gateway. A Lambda reutiliza somente IDs aceitos pelo seu validador; com `=`, `+` ou `/` ela usa o ID da invocação. Ver [Observabilidade](observability.md#correlação-fim-a-fim).
- **Webhook sem `x-request-id` da borda**: a assinatura `x-signature` do Mercado Pago é calculada sobre o `x-request-id` e o `data.id` da query string originais, então a integração `webhook-billing` mapeia só o caminho. A query string passa sem mapeamento.

## Como o documento é validado

Quatro camadas, em ordem de quando falham:

1. **Lint no CI** (`redocly lint`): falha no Pull Request. Pega sintaxe inválida, `$ref` sem destino, operação sem `responses`, response sem `description`.
2. **Guarda de rotas no CI**: falha no Pull Request quando `paths` declara caminho sob `/internal`, uma variável gulosa na raiz ou logo sob `/api`, ou `$default`, citando a rota.
3. **`fail_on_warnings = true`** no `aws_apigatewayv2_api`: falha no `apply`. Sem essa flag, uma integração com URI inválida produz uma **rota criada sem target** e um `apply` verde. Antes dele, o `plan` já falha com `Invalid index` se uma chave ou um dono de `route_owner` não existir.
4. **Verificação no recurso provisionado**: `aws apigatewayv2 get-routes` e `aws apigatewayv2 get-integrations` com `--api-id "$(terraform output -raw api_id)"` confirmam as rotas e os mappings publicados.

Para validar localmente:

```bash
npx --yes @redocly/cli@1.34.2 lint openapi/gateway.yaml \
  --extends=minimal --skip-rule=security-defined \
  --skip-rule=no-empty-servers --skip-rule=operation-operationId
cd terraform && terraform validate
```

O lint usa `--extends=minimal`, que mantém a validação **estrutural** ligada. As três regras puladas (`security-defined`, `no-empty-servers`, `operation-operationId`) são opinativas de estilo de API pública e não dizem nada sobre validade; o motivo de cada uma está no próprio step do workflow.

## Documentação relacionada

- 📐 [ADR 0002](adr/0002-contrato-do-gateway-em-openapi.md): as estratégias de contrato avaliadas e por que esta.
- 📐 [ADR 0005](adr/0005-integracao-privada-por-servico-e-tabela-de-donos.md): integração por serviço e tabela de donos.
- 🌍 [Terraform](terraform.md): o outro lado da divisão.
- 🔄 [CI/CD](ci-cd.md): o lint e a guarda de rotas, job a job.
