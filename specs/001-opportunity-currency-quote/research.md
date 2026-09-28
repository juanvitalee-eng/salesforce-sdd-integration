# Research: Cotizador de Oportunidades

**Feature**: `001-opportunity-currency-quote` | **Date**: 2026-09-28

No quedaron marcadores NEEDS CLARIFICATION en el Technical Context. Esta sección documenta las
decisiones técnicas y por qué se tomaron.

---

## 1. Cómo consultar Frankfurter

**Decision**: una sola llamada `GET {FrankfurterApi}/latest?base={MONEDA_ORIGINAL}` (sin
`symbols`) por cada **moneda original distinta** del lote. La respuesta trae todas las tasas de esa
moneda base, y el Service busca en ese mapa la moneda destino de cada pedido.

Comportamiento del proveedor (verificado contra la API real el 2026-09-28):

| Llamada | Respuesta | Interpretación |
|---|---|---|
| `/v1/latest?base=USD` | 200 `{"amount":1.0,"base":"USD","date":"2026-09-28","rates":{"EUR":0.87889,...}}` | OK. `rates` **no** incluye la moneda base |
| `/v1/latest?base=ARS` | 404 `{"message":"not found"}` | Moneda original no soportada → 400 `UNSUPPORTED_CURRENCY` |
| moneda destino ausente de `rates` (y distinta de la base) | — | Moneda destino no soportada → 400 `UNSUPPORTED_CURRENCY` |
| timeout (> 10 s), 5xx, 429, cuerpo ilegible, otros 4xx | — | Proveedor no disponible → 500 `EXCHANGE_RATE_UNAVAILABLE` |

- **Moneda destino = moneda original**: tipo de cambio 1. Se hace igual el callout para la base, así
  se aplica la misma regla de "moneda soportada" y la fecha/hora de cotización es real.
- **`date` del proveedor**: se guarda como `RateDate__c` (fecha de publicación de la tasa por el BCE),
  útil para auditoría porque Frankfurter no publica los fines de semana.

**Rationale**: con `base` sin `symbols` alcanza un callout por moneda base. Como las monedas
originales solo pueden ser monedas activas de la org, un lote de 200 pedidos usa típicamente 1 a 3
callouts, muy por debajo del límite de 100.

**Alternatives considered**:
- Un callout por pedido: rompe con 200 pedidos (límite de 100 callouts) y es lento.
- Consultar `/v1/currencies` antes para validar monedas: agrega un callout sin beneficio, porque el
  404 y la ausencia en `rates` ya informan lo mismo.
- Usar `symbols=`: con un símbolo inválido Frankfurter devuelve 404 para todo el pedido, y no se
  podría saber qué pedido falló.

## 2. Autenticación y endpoint (Named Credential sin autenticación)

**Decision**: Named Credential `FrankfurterApi` (URL `https://api.frankfurter.dev/v1`) respaldada por
la External Credential `FrankfurterNoAuth` con protocolo **No Authentication**. El acceso al
principal se otorga en el permission set `OpportunityQuoteUser`. El código llama a
`callout:FrankfurterApi/latest?base=USD`.

**Rationale**: cumple la regla 10 (nada de URLs hardcodeadas) con el modelo moderno de credenciales.
Si en el futuro cambia el proveedor o se necesita una API key, solo se cambia la credencial, no el
código.

**Resultado de la implementación (2026-09-28)**: la org rechazó `NoAuthentication` ("External
Credentials don't support the NoAuthentication authentication protocol"). Se usa protocolo **`Custom`
sin parámetros de autenticación**, que funciona igual para una API pública.

**Riesgo / plan B original**: si el deploy rechaza el valor `NoAuthentication` en `authenticationProtocol`,
crear la External Credential en Setup (Authentication Protocol: No Authentication), recuperarla con
`sf project retrieve start --metadata ExternalCredential:FrankfurterNoAuth` y versionar ese XML.

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
Number(18,6). Frankfurter publica a lo sumo 5 decimales, así que no se pierde precisión.

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
siempre sale de Frankfurter).

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
  `OpportunityQuoteResource` y `OpportunityQuoteAction`, principal de `FrankfurterNoAuth`) y
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
`NamedCredentialName__c = FrankfurterApi`.

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
