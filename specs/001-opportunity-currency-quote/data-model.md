# Data Model: Cotizador de Oportunidades

**Feature**: `001-opportunity-currency-quote` | **Date**: 2026-09-28

Convención (constitución, reglas 1 y 2): API Name en inglés, Label en español y descripción en español
en **todo** objeto y campo.

---

## Opportunity (estándar, solo lectura)

| Campo | Uso |
|---|---|
| `Id` | Identifica el pedido |
| `Amount` | Monto original. Si está vacío → `OPPORTUNITY_WITHOUT_AMOUNT` (400) |
| `CurrencyIsoCode` | Moneda original (org con Multi-Currency) |

Nunca se modifica (FR-019, regla 12). No se agregan campos ni triggers.

---

## CurrencyQuote__c: "Cotización de Moneda"

**Descripción**: Registro histórico e inmutable de cada cotización exitosa de una Oportunidad en otra
moneda. Se crea desde el canal externo o desde el agente, y nunca modifica la Oportunidad.

| Atributo | Valor |
|---|---|
| Label / Plural | Cotización de Moneda / Cotizaciones de Moneda |
| Name | Auto Number `CQ-{000000}` |
| Sharing (OWD) | Public Read Only |
| Enable Reports / History | Sí / No (no se edita) |

| API Name | Label | Tipo | Req. | Descripción |
|---|---|---|---|---|
| `Opportunity__c` | Oportunidad | Lookup(Opportunity), **deleteConstraint = Restrict** | Sí | Oportunidad cotizada. Impide borrar la Oportunidad mientras tenga cotizaciones (FR-020a). |
| `OriginalAmount__c` | Monto original | Number(16,2) | Sí | Monto de la Oportunidad al momento de cotizar, en su moneda original. |
| `OriginalCurrency__c` | Moneda original | Text(3) | Sí | Código ISO 4217 de la moneda de la Oportunidad (su CurrencyIsoCode). |
| `TargetCurrency__c` | Moneda destino | Text(3) | Sí | Código ISO 4217 de la moneda a la que se convirtió. |
| `ExchangeRate__c` | Tipo de cambio | Number(18,6) | Sí | Tipo de cambio informado por el proveedor (1 moneda original = X moneda destino). |
| `ConvertedAmount__c` | Monto convertido | Number(18,2) | Sí | Monto original × tipo de cambio, truncado a 2 decimales. |
| `QuotedAt__c` | Fecha/hora de cotización | DateTime | Sí | Momento en que el sistema obtuvo el tipo de cambio (UTC). |
| `RateDate__c` | Fecha de publicación de la tasa | Date | Sí | Fecha en que el proveedor publicó el tipo de cambio usado. |
| `Channel__c` | Canal de origen | Picklist restringido: `ExternalSystem` ("Sistema externo"), `Agent` ("Agente") | Sí | Canal que pidió la cotización. |

**Notas**:
- Montos en campos Number, no Currency (ver research §5). El `CurrencyIsoCode` estándar del registro
  no se usa.
- "Requerido" se impone a nivel de campo (`required = true`) para que los datos siempre estén completos.
- Relaciones: Opportunity 1 → N CurrencyQuote__c. Related list "Cotizaciones de Moneda" en el layout
  de Oportunidad.
- Ciclo de vida: **crear → consultar**. No hay estados ni actualizaciones (FR-020).

---

## ErrorLog__c: "Log de Errores"

**Descripción**: Log técnico genérico y reutilizable por cualquier funcionalidad. Registra cada
operación rechazada con su mensaje de negocio y su detalle técnico. Solo visible para administradores.

| Atributo | Valor |
|---|---|
| Label / Plural | Log de Errores / Logs de Errores |
| Name | Auto Number `ERR-{000000}` |
| Sharing (OWD) | Private |
| Acceso | Ningún permission set de negocio. Se inserta en `SYSTEM_MODE` (research §6). Los administradores lo consultan con el permission set `ErrorLogAdmin` (lectura de todos los campos + View All), necesario porque los campos no requeridos no tienen FLS por defecto |

| API Name | Label | Tipo | Req. | Descripción |
|---|---|---|---|---|
| `OccurredAt__c` | Fecha/hora | DateTime | Sí | Momento en que ocurrió el error. |
| `Source__c` | Funcionalidad de origen | Text(80) | Sí | Funcionalidad que generó el error (por ejemplo, "Cotizador de Oportunidades"). |
| `Channel__c` | Canal | Text(40) | No | Canal por el que llegó la operación (por ejemplo, "ExternalSystem", "Agent"). Texto libre para ser genérico. |
| `ErrorCode__c` | Código de error | Text(60) | Sí | Código estable del error (por ejemplo, OPPORTUNITY_NOT_FOUND). |
| `StatusCode__c` | Código HTTP | Number(3,0) | No | Código de estado devuelto al llamador (400, 500), si aplica. |
| `BusinessMessage__c` | Mensaje de negocio | Long Text Area(2000) | Sí | Mensaje claro que recibió el llamador. |
| `TechnicalDetail__c` | Detalle técnico | Long Text Area(32768) | No | Detalle interno para diagnóstico (excepción, stack trace, respuesta del proveedor). Nunca se devuelve al llamador. |
| `RelatedRecordId__c` | Id de registro relacionado | Text(18) | No | Id del registro involucrado (por ejemplo, la Oportunidad del pedido que falló). |
| `Context__c` | Contexto | Long Text Area(5000) | No | Datos adicionales, por ejemplo "Pedido 2 de 3, moneda destino XYZ". |

**Regla**: se crea exactamente **un** `ErrorLog__c` por llamada rechazada (SC-009), para el error de
menor posición.

---

## OpportunityQuoteSetting__mdt: "Configuración del Cotizador"

**Descripción**: Parámetros de negocio del Cotizador de Oportunidades, modificables sin desplegar
código.

| API Name | Label | Tipo | Valor `Default` | Descripción |
|---|---|---|---|---|
| `MaxRequestsPerCall__c` | Máximo de pedidos por llamada | Number(4,0) | 200 | Cantidad máxima de pedidos aceptados en una llamada (FR-004). |
| `CalloutTimeoutMs__c` | Timeout del proveedor (ms) | Number(6,0) | 10000 | Tiempo máximo de espera al proveedor de tipo de cambio (máximo 120000). |
| `NamedCredentialName__c` | Named Credential del proveedor | Text(80) | FrankfurterApi | Nombre de la Named Credential usada para el callout. |

---

## Wrappers Apex (no persistentes): `QuoteModels`

| Clase interna | Campos | Uso |
|---|---|---|
| `QuoteRequest` | `opportunityId`, `targetCurrency` | Un pedido |
| `BatchRequest` | `List<QuoteRequest> requests` | Body del POST |
| `QuoteResult` | `opportunityId`, `originalAmount`, `originalCurrency`, `targetCurrency`, `convertedAmount`, `exchangeRate`, `quotedAt`, `rateDate` | Una cotización exitosa |
| `BatchResponse` | `List<QuoteResult> quotes` | Respuesta 200 |
| `ErrorResponse` / `ErrorDetail` | `code`, `message`, `requestIndex`, `opportunityId` | Respuesta 400/500 |

Contrato JSON exacto: [contracts/opportunity-quotes-api.md](./contracts/opportunity-quotes-api.md).

---

## Catálogo de códigos de error

| Código | HTTP | Cuándo | Mensaje de negocio (ejemplo) |
|---|---|---|---|
| `INVALID_REQUEST_BODY` | 400 | JSON mal formado o sin `requests` | "El cuerpo del pedido no tiene el formato esperado." |
| `EMPTY_REQUEST_LIST` | 400 | `requests` vacío | "Debe enviar al menos un pedido de cotización." |
| `REQUEST_LIMIT_EXCEEDED` | 400 | Más de `MaxRequestsPerCall__c` | "Se pueden enviar como máximo 200 pedidos por llamada." |
| `INVALID_OPPORTUNITY_ID` | 400 | Id vacío, mal formado o que no es de Oportunidad | "Pedido 2: el Id '123' no es un Id de Oportunidad válido." |
| `OPPORTUNITY_NOT_FOUND` | 400 | No existe o no es visible | "Pedido 2: la Oportunidad indicada no existe." |
| `OPPORTUNITY_WITHOUT_AMOUNT` | 400 | `Amount` vacío | "Pedido 1: la Oportunidad no tiene monto para cotizar." |
| `INVALID_CURRENCY_CODE` | 400 | Moneda vacía o que no son 3 letras | "Pedido 1: 'euro' no es un código de moneda válido (use 3 letras, por ejemplo EUR)." |
| `UNSUPPORTED_CURRENCY` | 400 | Moneda original o destino no soportada por el proveedor | "Pedido 1: la moneda ARS no está soportada por el proveedor de tipo de cambio." |
| `EXCHANGE_RATE_UNAVAILABLE` | 500 | Timeout, 5xx, respuesta ilegible | "El tipo de cambio no está disponible en este momento. Intente nuevamente más tarde." |
| `INTERNAL_ERROR` | 500 | Cualquier error inesperado (incluye fallo del insert) | "Ocurrió un error inesperado al procesar la cotización." |
