# Research: Cotizador de Oportunidades

**Feature**: `001-opportunity-currency-quote` | **Date**: 2026-09-28

No quedaron marcadores NEEDS CLARIFICATION en el Technical Context. Esta sección documenta las
decisiones técnicas y por qué se tomaron.

---

## 1. Cómo consultar el proveedor (currency-api)

> **Cambio 2026-09-28**: el diseño original usaba Frankfurter (BCE, ~30 monedas). Se reemplazó por
> currency-api porque Frankfurter **no publica ARS**, que es una moneda activa de la org.

**Decision**: una sola llamada `GET {CurrencyApi}/currencies/{moneda_original_en_minúsculas}.json` por
cada **moneda original distinta** del lote. La respuesta trae todas las tasas de esa moneda base y el
Service busca en ese mapa la moneda destino de cada pedido.

Comportamiento del proveedor (verificado contra la API real el 2026-09-28):

| Llamada | Respuesta | Interpretación |
|---|---|---|
| `/currencies/usd.json` | 200 `{"date":"2026-09-28","usd":{"ars":1521.76514116,"eur":0.87803741,...}}` | OK. La clave del mapa de tasas es la propia moneda base, en minúsculas |
| `/currencies/xyz.json` | 404 | Moneda original no publicada → 400 `UNSUPPORTED_CURRENCY` |
| `/currencies/USD.json` | 404 | **El código va siempre en minúsculas** (el cliente lo convierte) |
| moneda destino ausente de las tasas | — | Moneda destino no publicada → 400 `UNSUPPORTED_CURRENCY` |
| timeout (> 10 s), 5xx, 429, cuerpo ilegible | — | Proveedor no disponible → 500 `EXCHANGE_RATE_UNAVAILABLE` |

- Las tasas llegan con hasta 11 decimales (ARS→USD = 0.00065713162). Se usan completas para el cálculo
  y se guardan en un campo Number(18,10) (§4).
- El cliente normaliza las claves a MAYÚSCULAS para que el resto del sistema siga usando códigos ISO.
- Como la clave del mapa varía según la moneda base (`"usd"`, `"ars"`, ...), el cliente la renombra a
  `"rates"` antes de deserializar con un wrapper tipado (misma técnica que con `"date"`).
- **Moneda destino = moneda original**: tipo de cambio 1 (igual se hace el callout para validar la base).
- `date` se guarda como `RateDate__c`.
- El proveedor también publica criptomonedas; quedan excluidas por la lista de monedas habilitadas (§11).
- Existe un dominio de respaldo (`latest.currency-api.pages.dev`); **no** se usa en v1 (un solo endpoint,
  configurable en la Named Credential si hiciera falta cambiarlo).

- **Limitación conocida (vista en vivo el 2026-09-28)**: el proveedor se sirve desde una CDN con `@latest`,
  que cachea las respuestas. Dos llamadas con minutos de diferencia pueden recibir tasas de días distintos
  (ej. USD con `date` 2026-09-27 y ARS con 2026-09-28) o nodos con versiones distintas. Por eso cada
  cotización guarda `RateDate__c`: SC-006 se cumple para el mismo tipo de cambio, no necesariamente para
  el mismo minuto. Si hiciera falta más consistencia, la mejora sería consultar la fecha explícita
  (`@<fecha>` en la URL) en lugar de `@latest`.

**Rationale**: igual que antes, un callout por moneda base; un lote de 200 pedidos usa típicamente 1 a 3.

**Alternatives considered**: Frankfurter (sin ARS); ExchangeRate-API `open.er-api.com` (también sin key y
con ARS; el usuario eligió currency-api); un callout por pedido (rompe el límite de 100 callouts).

## 2. Autenticación y endpoint (Named Credential sin autenticación)

**Decision**: Named Credential `CurrencyApi` (URL `https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1`)
respaldada por la External Credential `CurrencyApiNoAuth` (protocolo `Custom` sin parámetros, ver abajo). El acceso al
principal se otorga en el permission set `OpportunityQuoteUser`. El código llama a
`callout:CurrencyApi/currencies/usd.json`.

**Rationale**: cumple la regla 10 (nada de URLs hardcodeadas) con el modelo moderno de credenciales.
Si en el futuro cambia el proveedor o se necesita una API key, solo se cambia la credencial, no el
código.

**Resultado de la implementación (2026-09-28)**: la org rechazó `NoAuthentication` ("External
Credentials don't support the NoAuthentication authentication protocol"). Se usa protocolo **`Custom`
sin parámetros de autenticación**, que funciona igual para una API pública.

**Riesgo / plan B original**: si el deploy rechaza el valor `NoAuthentication` en `authenticationProtocol`,
crear la External Credential en Setup (Authentication Protocol: No Authentication), recuperarla con
`sf project retrieve start --metadata ExternalCredential:CurrencyApiNoAuth` y versionar ese XML.

**Alternatives considered**: Named Credential "legacy" (deprecada para nuevos desarrollos); Remote
Site Setting + URL en Custom Metadata (funciona, pero es menos seguro y no es la práctica
recomendada).

## 3. Orden de procesamiento y "todo o nada" con el primer error por posición

**Decision**: el Service evalúa **todos** los pedidos en etapas y guarda, para cada uno, un resultado
o un error. Después elige el error de **menor posición**:

1. Validación del lote: cuerpo, lista vacía, máximo de pedidos. Un error acá corta de inmediato; es
   un error de la llamada entera, sin posición.
2. Validación de formato por pedido: Id con formato válido y de tipo Opportunity; moneda destino con
   formato `^[A-Za-z]{3}$`, normalizada a mayúsculas.
3. Una sola SOQL `WITH USER_MODE` sobre los Ids válidos → no existe o no es visible
   (`OPPORTUNITY_NOT_FOUND`); `Amount` vacío (`OPPORTUNITY_WITHOUT_AMOUNT`).
4. Callouts, uno por moneda base distinta, solo para los pedidos que pasaron 1 a 3.
5. Cálculo.
6. Si hubo algún error: se loguea el de menor posición y se lanza. Si no hubo errores: `insert` de
   todas las `CurrencyQuote__c`.

**Rationale**: la spec (FR-010) pide el código del *primer error en el orden de los pedidos*. Si se
cortara en la primera etapa que falla, un proveedor caído podría "tapar" un Id inválido en el pedido 1.
El costo es bajo: la SOQL y los callouts son los mismos.

**Alternatives considered**: cortar ante el primer error que aparezca (más simple, pero no cumple
FR-010); devolver resultados parciales (descartado por la clarificación "todo o nada").

## 4. Cálculo y precisión

**Decision**: `convertedAmount = (amount * rate).setScale(2, System.RoundingMode.DOWN)`. `DOWN`
trunca hacia cero (FR-012). El tipo de cambio se guarda tal cual lo devuelve el proveedor, en un campo
Number(18,10). currency-api publica hasta 11 decimales: el cálculo usa la tasa completa y se guardan
10 decimales (suficiente para monedas de bajo valor como ARS: 0.0006571316).

**Rationale**: `RoundingMode.DOWN` es exactamente "truncar hacia cero"; `FLOOR` redondearía los
negativos hacia abajo (−1,239 → −1,24), lo que no es truncar.

## 5. Multi-Currency: cómo tratar montos en `CurrencyQuote__c`

**Decision**: los montos de la cotización se guardan en campos **Number**, no Currency, junto a
campos de texto con el código ISO (`OriginalCurrency__c`, `TargetCurrency__c`). La moneda original
se lee de `Opportunity.CurrencyIsoCode`. El campo estándar `CurrencyIsoCode` de la cotización queda
con el valor por defecto y no se usa.

**Rationale**: en una org Multi-Currency, todos los campos Currency de un registro comparten una sola
moneda (`CurrencyIsoCode`), pero cada cotización tiene **dos** monedas. Además, la moneda destino
puede no estar activa en la org (por ejemplo, JPY), y asignarla a `CurrencyIsoCode` daría error de
DML. Los campos Number evitan conversiones automáticas de Salesforce que no queremos (la tasa
siempre sale del proveedor externo).

**Alternatives considered**: campos Currency con `CurrencyIsoCode = moneda destino` (falla con
monedas no activas y muestra mal el monto original).

## 6. Log de errores genérico sin exponer datos a usuarios de negocio

**Decision**: `ErrorLogger` es una clase `with sharing` que inserta `ErrorLog__c` con
`Database.insert(logs, AccessLevel.SYSTEM_MODE)`. `ErrorLog__c` tiene OWD **Private** y no se otorga
en ningún permission set de negocio; lo ven solo los administradores ("View All Data"). El Service
atrapa el error, lo loguea y lo **vuelve a lanzar**; el adaptador (REST o agente) lo traduce.

**Rationale**:
- `SYSTEM_MODE` ignora permisos de objeto y campo solo para ese insert. El usuario de integración y
  los usuarios del agente pueden generar logs sin poder leerlos (FR-024).
- Como la excepción se atrapa en el adaptador y no escapa sin control, la transacción **no** se
  revierte y el log persiste aunque el lote se rechace (FR-022).
- El insert del log ocurre después de los callouts (regla 5 OK).
- Estructura genérica: `Source__c`, `Channel__c`, `ErrorCode__c`, `StatusCode__c`,
  `RelatedRecordId__c`, `Context__c`. Nada es específico del Cotizador (FR-023).

**Alternatives considered**: Platform Events con "Publish Immediately" (sobreviven al rollback, pero
son innecesarios porque acá no hay rollback y agregan complejidad); dar Create sobre `ErrorLog__c` en
el permission set (funciona, pero agrega permisos sobre un objeto técnico).

## 7. Permisos y visibilidad

**Decision**:
- SOQL de Oportunidades con `WITH USER_MODE`: respeta sharing, permisos de objeto y FLS del usuario
  que llama. Una Oportunidad no visible = `OPPORTUNITY_NOT_FOUND` (sin revelar que existe).
- Inserción de `CurrencyQuote__c` con `AccessLevel.USER_MODE`: el usuario necesita Create, otorgado
  por `OpportunityQuoteUser`.
- `CurrencyQuote__c`: OWD **Public Read Only**. Nadie tiene Edit/Delete salvo administradores
  (FR-020).
- Permission sets: `OpportunityQuoteUser` (usuario de integración + usuarios internos del agente:
  Read Opportunity/Amount, Create+Read `CurrencyQuote__c`, acceso a las clases
  `OpportunityQuoteResource` y `OpportunityQuoteAction`, principal de `CurrencyApiNoAuth` y Read sobre `UserExternalCredential`) y
  `CurrencyQuoteAuditor` (solo Read `CurrencyQuote__c`).

**Rationale**: Public Read Only permite que el auditor vea todas las cotizaciones. Con Lookup no
existe "Controlled by Parent" (eso requiere Master-Detail, descartado en la clarificación).

## 8. Canal agente (Agentforce)

**Decision**: la clase `OpportunityQuoteAction` expone un `@InvocableMethod` con entradas
`opportunityId` y `targetCurrency` (ambas obligatorias) y salidas tipadas (`isSuccess`, `message`
más los seis datos). En Agentforce Builder se crea una **Agent Action** de tipo Apex y un **Topic**
"Cotización de Oportunidades" con instrucciones. Después la metadata (`GenAiFunction`,
`GenAiPlugin`) se recupera al repo con `sf project retrieve start`.

- FR-016 (pedir datos faltantes): se cubre con entradas marcadas como obligatorias ("Require Input")
  más la instrucción del topic "si falta el Id o la moneda, pedíselos al usuario antes de ejecutar la
  acción".
- Errores: la acción **no** lanza excepciones al agente. Devuelve `isSuccess = false` con el mismo
  mensaje de negocio que el canal externo, y la instrucción del topic prohíbe inventar valores.

**Rationale**: construir el agente en el Builder es el flujo soportado y más didáctico. Recuperar la
metadata deja todo versionado en git.

**Alternatives considered**: escribir a mano la metadata `GenAiPlannerBundle`/`GenAiPlugin` (frágil
y poco documentada); usar un Flow como acción (duplicaría el adaptador sin beneficio).

## 9. Configuración (Custom Metadata)

**Decision**: `OpportunityQuoteSetting__mdt` con un registro `Default`:
`MaxRequestsPerCall__c = 200`, `CalloutTimeoutMs__c = 10000`,
`NamedCredentialName__c = CurrencyApi`.

**Rationale**: regla 10. Estos valores se pueden cambiar sin desplegar código (spec: "se puede
ajustar por configuración").

## 10. Estrategia de tests

**Decision**: `ExchangeRateCalloutMock` implementa `HttpCalloutMock` y se configura por moneda base
(código HTTP + cuerpo, o excepción de timeout). `QuoteTestDataFactory` crea Oportunidades en USD y
EUR. Se cubren todos los escenarios de aceptación y casos borde con aserciones sobre: código HTTP,
código de error, mensaje, cantidad de `CurrencyQuote__c` y `ErrorLog__c` creados, y la Oportunidad
sin cambios.

**Prerequisito de org**: los tests usan `CurrencyIsoCode`, así que requieren Multi-Currency con al
menos **USD y EUR activas** en `sdd-dev` (ver quickstart).

## 11. Lista de monedas habilitadas (FR-025, FR-026)

**Decision**: Custom Metadata Type `QuoteCurrency__mdt` ("Moneda del Cotizador"): un registro por moneda,
con `DeveloperName` = código ISO (ej. `ARS`) y un checkbox `IsActive__c`. `OpportunityQuoteSettings`
expone `enabledCurrencies()` (solo las activas). El Service valida la moneda destino en la etapa 2 y la
moneda original en la etapa 3, **antes** de cualquier callout (FR-026).

- Se mantiene el código de error `UNSUPPORTED_CURRENCY` (contrato estable para el ERP); el mensaje
  distingue "no está habilitada en el Cotizador" de "no es publicada por el proveedor".
- Registros iniciales: USD, EUR, ARS, GBP, BRL, CLP, MXN, UYU (editables desde Setup → Custom Metadata Types).
- Tests: `OpportunityQuoteSettings` tiene un override `@TestVisible` para simular listas distintas.

**Alternatives considered**: Custom Setting (CMDT se despliega junto con el código y es lo que pide la
constitución, regla 10); un campo de texto con códigos separados por coma (más fácil de romper, sin
activar/desactivar por moneda).
