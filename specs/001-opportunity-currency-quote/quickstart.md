# Quickstart: validar el Cotizador de Oportunidades

Guía para probar de punta a punta que la feature funciona. Los comandos se corren desde
`salesforce-sdd-integration/` (donde está `sfdx-project.json`).

## Prerrequisitos

1. Org `sdd-dev` autenticada: `sf org display --target-org sdd-dev`.
2. Multi-Currency habilitado con **USD y EUR activas** (Setup → Company Information → Currencies).
   Opcional: activar una moneda no soportada por Frankfurter (por ejemplo, ARS) para probar ese error.
3. Agentforce habilitado, con el agente de empleados (Agentforce Employee Agent) activo.

## 1. Desplegar y asignar permisos

```bash
sf project deploy start --source-dir force-app --target-org sdd-dev
sf org assign permset --name OpportunityQuoteUser --target-org sdd-dev
sf org assign permset --name CurrencyQuoteAuditor --target-org sdd-dev
```

## 2. Tests automáticos (constitución, regla 13)

```bash
sf apex run test --target-org sdd-dev --code-coverage --result-format human --wait 10 \
  --tests OpportunityQuoteServiceTest OpportunityQuoteResourceTest OpportunityQuoteActionTest \
          ExchangeRateClientTest ErrorLoggerTest CurrencyQuoteAuditTest
```

**Esperado**: 100% de los tests pasan y cada clase tiene 85% de cobertura o más. Ningún test llama a
Frankfurter (todos usan `ExchangeRateCalloutMock`).

## 3. Datos de prueba

Crear dos Oportunidades (desde la UI o con `sf data create record`) y anotar sus Ids:
- **OPP_USD**: Amount 10000, CurrencyIsoCode USD.
- **OPP_SIN_MONTO**: Amount vacío.

## 4. Canal externo (Historia 1)

Obtener URL y token con `sf org display --target-org sdd-dev`, y después:

```bash
curl -s -X POST "$INSTANCE_URL/services/apexrest/v1/opportunity-quotes" \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"requests":[{"opportunityId":"<OPP_USD>","targetCurrency":"eur"}]}'
```

| # | Pedido | Esperado |
|---|---|---|
| 4.1 | OPP_USD → `eur` | 200; `convertedAmount` = 10000 × `exchangeRate` truncado; `quotedAt` en UTC |
| 4.2 | OPP_USD → `USD` | 200; `exchangeRate` = 1, `convertedAmount` = 10000 |
| 4.3 | Id `006000000000000AAA` | 400 `OPPORTUNITY_NOT_FOUND`, `requestIndex` 1 |
| 4.4 | OPP_USD → `XYZ` | 400 `UNSUPPORTED_CURRENCY` |
| 4.5 | OPP_USD → `euro` | 400 `INVALID_CURRENCY_CODE` |
| 4.6 | OPP_SIN_MONTO → `EUR` | 400 `OPPORTUNITY_WITHOUT_AMOUNT` |
| 4.7 | `[OPP_USD→EUR, Id inexistente, OPP_USD→GBP]` | 400, `requestIndex` 2, **ninguna** cotización creada |
| 4.8 | `{"requests":[]}` | 400 `EMPTY_REQUEST_LIST` |

El caso "proveedor caído" (500 `EXCHANGE_RATE_UNAVAILABLE`) se valida con los tests con mock. Para
verlo en vivo, cambiar temporalmente la URL de la Named Credential `FrankfurterApi` a un host
inexistente.

Contrato completo: [contracts/opportunity-quotes-api.md](./contracts/opportunity-quotes-api.md).

## 5. Canal agente (Historia 2)

Configurar la acción y el topic según [contracts/agent-action.md](./contracts/agent-action.md).
Después, en el panel de Agentforce:

| # | Mensaje | Esperado |
|---|---|---|
| 5.1 | "cotizame la oportunidad <OPP_USD> en EUR" | Responde los 6 datos. Los valores coinciden con 4.1 si el `rateDate` es el mismo (SC-006) |
| 5.2 | "cotizame una oportunidad en EUR" | El agente pide el Id antes de ejecutar (FR-016) |
| 5.3 | "cotizame la oportunidad 006000000000000AAA en EUR" | Explica que la Oportunidad no existe; no inventa valores |

## 6. Auditoría (Historia 3)

```bash
sf data query --target-org sdd-dev --query \
  "SELECT Name, Opportunity__c, OriginalAmount__c, OriginalCurrency__c, TargetCurrency__c, ExchangeRate__c, ConvertedAmount__c, QuotedAt__c, Channel__c FROM CurrencyQuote__c ORDER BY CreatedDate DESC"
sf data query --target-org sdd-dev --query \
  "SELECT Name, ErrorCode__c, StatusCode__c, Channel__c, BusinessMessage__c FROM ErrorLog__c ORDER BY CreatedDate DESC"
```

**Esperado**:
- Una `CurrencyQuote__c` por cada cotización exitosa (4.1, 4.2 y 5.1), con el canal correcto.
- Un `ErrorLog__c` por cada llamada rechazada (4.3 a 4.8, 5.3) y ninguno para las exitosas.
- OPP_USD sigue con Amount 10000 y USD (SC-004).
- Intentar borrar OPP_USD desde la UI → la plataforma lo impide porque tiene cotizaciones (FR-020a).
- Un usuario con solo `CurrencyQuoteAuditor` ve las cotizaciones pero no puede editarlas ni ve
  `ErrorLog__c`.

## Checklist de revisión de código (reglas de la constitución)

- [ ] Todas las clases son `with sharing` y tienen comentarios que explican qué hacen y por qué.
- [ ] No hay SOQL ni DML dentro de loops; todos los callouts ocurren antes del primer DML.
- [ ] No hay URLs ni valores de configuración hardcodeados.
- [ ] Todo objeto y campo tiene Label y descripción en español.
