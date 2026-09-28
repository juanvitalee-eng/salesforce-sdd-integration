# Contrato REST: Cotizaciones de Oportunidades (canal externo)

Versión OpenAPI: [opportunity-quotes.openapi.yaml](./opportunity-quotes.openapi.yaml)

## Endpoint

```
POST /services/apexrest/v1/opportunity-quotes
Authorization: Bearer <access token del usuario de integración>
Content-Type: application/json
```

Clase: `OpportunityQuoteResource` (`@RestResource(urlMapping='/v1/opportunity-quotes')`, `@HttpPost`).

## Request

```json
{
  "requests": [
    { "opportunityId": "006Hs00001AbCdEIAV", "targetCurrency": "EUR" },
    { "opportunityId": "006Hs00001XyZwQIAV", "targetCurrency": "gbp" }
  ]
}
```

| Campo | Tipo | Reglas |
|---|---|---|
| `requests` | array | Obligatorio, de 1 a `MaxRequestsPerCall__c` (200) elementos |
| `requests[].opportunityId` | string | Id de Oportunidad de 15 o 18 caracteres |
| `requests[].targetCurrency` | string | 3 letras ISO 4217, sin distinguir mayúsculas de minúsculas |

Se permite repetir el mismo `opportunityId`: cada pedido es independiente.

## Response 200: todos los pedidos OK

Un elemento por pedido, **en el mismo orden** del request.

```json
{
  "quotes": [
    {
      "opportunityId": "006Hs00001AbCdEIAV",
      "originalAmount": 10000.00,
      "originalCurrency": "USD",
      "targetCurrency": "EUR",
      "exchangeRate": 0.87889,
      "convertedAmount": 8788.90,
      "quotedAt": "2026-09-28T14:03:12.000Z",
      "rateDate": "2026-09-28"
    }
  ]
}
```

- `convertedAmount` = `originalAmount × exchangeRate`, truncado a 2 decimales.
- `quotedAt` en ISO 8601 UTC; `rateDate` es la fecha de publicación de la tasa (`YYYY-MM-DD`).
- Efecto: se crea un `CurrencyQuote__c` por pedido, con `Channel__c = ExternalSystem`.

## Response 400 / 500: la llamada se rechaza entera

```json
{
  "error": {
    "code": "OPPORTUNITY_NOT_FOUND",
    "message": "Pedido 2 (Id 006Hs00001XyZwQIAV): la Oportunidad indicada no existe.",
    "requestIndex": 2,
    "opportunityId": "006Hs00001XyZwQIAV"
  }
}
```

| Campo | Descripción |
|---|---|
| `code` | Código estable, pensado para que lo lea una máquina (ver catálogo en [data-model.md](../data-model.md#catálogo-de-códigos-de-error)) |
| `message` | Texto en español para una persona de negocio. Nunca incluye stack traces ni nombres internos |
| `requestIndex` | Posición **1-based** del pedido que falló; `null` si el error es de toda la llamada (body, lista vacía, límite) |
| `opportunityId` | Id tal como vino en el pedido que falló; `null` si no aplica |

Reglas:
- Si fallan varios pedidos, se informa el de **menor posición**; su código define el HTTP status.
- No se devuelve ninguna cotización ni se crea ningún `CurrencyQuote__c`.
- Se crea exactamente un `ErrorLog__c`.

| HTTP | Códigos |
|---|---|
| 400 | `INVALID_REQUEST_BODY`, `EMPTY_REQUEST_LIST`, `REQUEST_LIMIT_EXCEEDED`, `INVALID_OPPORTUNITY_ID`, `OPPORTUNITY_NOT_FOUND`, `OPPORTUNITY_WITHOUT_AMOUNT`, `INVALID_CURRENCY_CODE`, `UNSUPPORTED_CURRENCY` |
| 500 | `EXCHANGE_RATE_UNAVAILABLE`, `INTERNAL_ERROR` |

> Nota: los errores de autenticación (401) y de permiso sobre la clase (403/404) los devuelve la
> plataforma antes de llegar al código y no siguen este formato.
