---

description: "Task list for feature 001: Cotizador de Oportunidades"
---

# Tasks: Cotizador de Oportunidades

**Input**: Design documents from `specs/001-opportunity-currency-quote/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: **SÍ se incluyen.** La constitución (regla 13) exige clases de test con ≥ 85% de cobertura
usando `HttpCalloutMock`. En Apex, un test no compila si la clase que prueba todavía no existe, así
que en cada historia los tests van **después** de la clase que prueban. Cada historia cierra con un
deploy y una corrida de tests.

**Organization**: Tareas agrupadas por historia de usuario para poder implementarlas y probarlas por
separado.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: se puede hacer en paralelo (archivo distinto, sin depender de tareas pendientes)
- **[Story]**: historia a la que pertenece (US1, US2, US3)

## Path Conventions

- `FA/` = `salesforce-sdd-integration/force-app/main/default/` (el proyecto SFDX vive en la subcarpeta
  `salesforce-sdd-integration/`). Los comandos `sf` se corren desde `salesforce-sdd-integration/`.
- Cada clase Apex lleva su `.cls-meta.xml` con `apiVersion` 67.0.
- **Reglas que aplican a TODAS las tareas de código** (constitución):
  - Todas las clases son `with sharing`, incluidas las de test.
  - Cada clase y método lleva comentarios en español que explican qué hace y por qué, escritos para
    alguien que no es programador.
  - No hay SOQL ni DML dentro de loops, y no hay valores hardcodeados.
  - Todo objeto y campo tiene Label y `<description>` en español.
- **Tests con callouts** (aplica a todo test que llegue a `ExchangeRateClient`):
  - Crear los datos en `@TestSetup` (o antes de `Test.startTest()`).
  - Hacer la llamada al Service, al Resource o a la acción **entre `Test.startTest()` y
    `Test.stopTest()`**, con `Test.setMock(HttpCalloutMock.class, mock)`.
  - Si no se hace así, Apex falla con "You have uncommitted work pending".

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: dejar el proyecto y la org listos.

- [X] T001 Crear las carpetas de metadata `FA/classes/`, `FA/objects/`, `FA/customMetadata/`, `FA/externalCredentials/`, `FA/namedCredentials/`, `FA/permissionsets/`, `FA/layouts/` bajo `salesforce-sdd-integration/force-app/main/default/`
- [X] T002 Verificar los prerrequisitos de la org: `sf org display --target-org sdd-dev` responde, y Multi-Currency está habilitado con **USD y EUR activas** (consulta: `sf data query -q "SELECT IsoCode, IsActive FROM CurrencyType" --target-org sdd-dev`). Si falta alguna moneda, detenerse y avisar al usuario

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: configuración, credenciales, objetos de datos, excepciones, wrappers, log genérico y cliente del proveedor. Todo esto lo usan las tres historias.

**⚠️ CRITICAL**: ninguna historia puede empezar hasta terminar esta fase.

### Configuración y credenciales

- [X] T003 [P] Crear el Custom Metadata Type `OpportunityQuoteSetting__mdt` (Label "Configuración del Cotizador", descripción "Parámetros de negocio del Cotizador de Oportunidades, modificables sin desplegar código.") en `FA/objects/OpportunityQuoteSetting__mdt/OpportunityQuoteSetting__mdt.object-meta.xml`, con los campos en `FA/objects/OpportunityQuoteSetting__mdt/fields/`: `MaxRequestsPerCall__c` (Label "Máximo de pedidos por llamada", Number(4,0)), `CalloutTimeoutMs__c` (Label "Timeout del proveedor (ms)", Number(6,0), descripción que indique máximo 120000), `NamedCredentialName__c` (Label "Named Credential del proveedor", Text(80)). Las descripciones se copian de [data-model.md](./data-model.md)
- [X] T004 Crear el registro `Default` en `FA/customMetadata/OpportunityQuoteSetting.Default.md-meta.xml` con `MaxRequestsPerCall__c = 200`, `CalloutTimeoutMs__c = 10000`, `NamedCredentialName__c = FrankfurterApi` (depende de T003)
- [X] T005 [P] Crear la External Credential `FrankfurterNoAuth` (Label "Frankfurter - Sin autenticación", `authenticationProtocol` = `NoAuthentication`, un principal de tipo `NamedPrincipal` llamado `FrankfurterPrincipal`) en `FA/externalCredentials/FrankfurterNoAuth.externalCredential-meta.xml`. Desplegar **solo** esta credencial primero (`sf project deploy start --metadata ExternalCredential:FrankfurterNoAuth --target-org sdd-dev`). **Plan B** si el deploy rechaza `NoAuthentication`: crearla en Setup (Named Credentials → External Credentials → Authentication Protocol: No Authentication), recuperarla con `sf project retrieve start --metadata ExternalCredential:FrankfurterNoAuth --target-org sdd-dev` y versionar ese XML (research §2)
- [X] T006 Crear la Named Credential `FrankfurterApi` (Label "API Frankfurter", tipo `SecuredEndpoint`, URL `https://api.frankfurter.dev/v1`, External Credential `FrankfurterNoAuth`, `generateAuthorizationHeader` = false) en `FA/namedCredentials/FrankfurterApi.namedCredential-meta.xml` (depende de T005)

### Objetos de datos

- [X] T007 [P] Crear el objeto `ErrorLog__c` en `FA/objects/ErrorLog__c/ErrorLog__c.object-meta.xml`: Label "Log de Errores", plural "Logs de Errores", Name Auto Number `ERR-{000000}`, `sharingModel` = `Private`, descripción de [data-model.md](./data-model.md)
- [X] T008 [P] Crear los campos de `ErrorLog__c` en `FA/objects/ErrorLog__c/fields/`, con Label y descripción de [data-model.md](./data-model.md): `OccurredAt__c` DateTime requerido; `Source__c` Text(80) requerido; `Channel__c` Text(40); `ErrorCode__c` Text(60) requerido; `StatusCode__c` Number(3,0); `BusinessMessage__c` Long Text Area(2000) requerido; `TechnicalDetail__c` Long Text Area(32768); `RelatedRecordId__c` Text(18); `Context__c` Long Text Area(5000)
- [X] T009 [P] Crear el objeto `CurrencyQuote__c` en `FA/objects/CurrencyQuote__c/CurrencyQuote__c.object-meta.xml`: Label "Cotización de Moneda", plural "Cotizaciones de Moneda", Name Auto Number `CQ-{000000}`, `sharingModel` = `Read` (Public Read Only), `enableReports` = true, `enableHistory` = false, descripción de [data-model.md](./data-model.md)
- [X] T010 [P] Crear los campos de `CurrencyQuote__c` en `FA/objects/CurrencyQuote__c/fields/`, todos `required = true` y con Label y descripción de [data-model.md](./data-model.md):
  - `Opportunity__c`: Lookup(Opportunity), `deleteConstraint` = `Restrict`, relationshipName `CurrencyQuotes`, relationshipLabel "Cotizaciones de Moneda".
  - Montos y tasa: `OriginalAmount__c` Number(16,2); `ExchangeRate__c` Number(18,6); `ConvertedAmount__c` **Number(18,2)**.
  - Monedas: `OriginalCurrency__c` Text(3); `TargetCurrency__c` Text(3).
  - Fechas: `QuotedAt__c` DateTime; `RateDate__c` Date.
  - `Channel__c`: Picklist restringido con los valores `ExternalSystem` (Label "Sistema externo") y `Agent` (Label "Agente").
  - Montos en Number, **no** Currency (research §5)

### Log de errores genérico

- [X] T011 Crear `ErrorLogger` en `FA/classes/ErrorLogger.cls`:
  - Clase interna `Entry` (source, channel, errorCode, statusCode, businessMessage, technicalDetail, relatedRecordId, context).
  - Método `public static void log(List<Entry> entries)` que arma los `ErrorLog__c` con `OccurredAt__c = Datetime.now()`. **Antes de insertar, recorta cada campo de texto a su largo máximo** (con `Schema.SObjectType.ErrorLog__c.fields.<Campo>.getLength()` y `String.abbreviate`), para que un dato largo nunca impida guardar el log. Inserta con `Database.insert(records, AccessLevel.SYSTEM_MODE)` (research §6).
  - Si el insert falla igual, **nunca** lanza una excepción: la atrapa y hace `System.debug`.
  - Sobrecarga `log(Entry e)`.
  - Nada en la clase es específico del Cotizador (FR-023) (depende de T008)

### Excepciones y wrappers

- [X] T012 [P] Crear `QuoteException` en `FA/classes/QuoteException.cls`: `public virtual with sharing class QuoteException extends Exception`, con las propiedades `errorCode`, `httpStatus` (Integer), `requestIndex` (Integer, 1-based, nullable), `opportunityId` (String) y `technicalDetail`, más constantes `public static final String` para los 10 códigos del catálogo de [data-model.md](./data-model.md#catálogo-de-códigos-de-error) (`INVALID_REQUEST_BODY`, `EMPTY_REQUEST_LIST`, `REQUEST_LIMIT_EXCEEDED`, `INVALID_OPPORTUNITY_ID`, `OPPORTUNITY_NOT_FOUND`, `OPPORTUNITY_WITHOUT_AMOUNT`, `INVALID_CURRENCY_CODE`, `UNSUPPORTED_CURRENCY`, `EXCHANGE_RATE_UNAVAILABLE`, `INTERNAL_ERROR`) y un método de fábrica que fija código, mensaje de negocio, status, posición e Id
- [X] T013 [P] Crear `QuoteValidationException extends QuoteException` (httpStatus 400) en `FA/classes/QuoteValidationException.cls` (depende de T012)
- [X] T014 [P] Crear `ExchangeRateUnavailableException extends QuoteException` (httpStatus 500, código `EXCHANGE_RATE_UNAVAILABLE`) en `FA/classes/ExchangeRateUnavailableException.cls` (depende de T012)
- [X] T015 [P] Crear `QuoteModels` en `FA/classes/QuoteModels.cls` con las clases internas del contrato [opportunity-quotes-api.md](./contracts/opportunity-quotes-api.md): `QuoteRequest` (opportunityId, targetCurrency), `BatchRequest` (List<QuoteRequest> requests), `QuoteResult` (opportunityId, originalAmount, originalCurrency, targetCurrency, exchangeRate, convertedAmount, quotedAt Datetime, rateDate Date), `BatchResponse` (List<QuoteResult> quotes), `ErrorResponse` (ErrorDetail error), `ErrorDetail` (code, message, requestIndex, opportunityId). Los nombres de propiedad deben coincidir **exactamente** con el JSON del contrato
- [X] T016 [P] Crear `OpportunityQuoteSettings` en `FA/classes/OpportunityQuoteSettings.cls`: lee `OpportunityQuoteSetting__mdt.getInstance('Default')` y expone `maxRequestsPerCall()`, `calloutTimeoutMs()` y `namedCredentialName()`, con valores por defecto 200 / 10000 / 'FrankfurterApi' si el registro no existe. Agregar un `@TestVisible static OpportunityQuoteSetting__mdt testOverride` para que los tests puedan simular otra configuración

### Cliente del proveedor (integración)

- [X] T017 Crear `ExchangeRateClient` en `FA/classes/ExchangeRateClient.cls`:
  - Clase interna `RateTable` (baseCurrency, isSupported Boolean, rateDate Date, `Map<String, Decimal> rates`, fetchedAt Datetime).
  - Método `public static Map<String, RateTable> getRates(Set<String> baseCurrencies)`, que hace **un** `GET callout:<namedCredentialName>/latest?base=<CODE>` (sin `symbols`) por moneda base, con el timeout de `OpportunityQuoteSettings`.
  - Reglas (research §1): 200 → parsear `date` y `rates` con un wrapper tipado (no `Map<String,Object>`), `isSupported = true`, `fetchedAt = Datetime.now()`; 404 → `isSupported = false`; cualquier otro status, `CalloutException` (timeout) o JSON ilegible → lanzar `ExchangeRateUnavailableException` con `technicalDetail` (status + body) (depende de T006, T014, T016)
- [X] T018 [P] Crear `ExchangeRateCalloutMock implements HttpCalloutMock` (`@IsTest`) en `FA/classes/ExchangeRateCalloutMock.cls`. Se configura por moneda base (`withRates(base, date, Map<String,Decimal>)`, `withStatus(base, code, body)`, `withTimeout(base)`, que lanza `CalloutException`) y cuenta cuántas llamadas recibió (`callCount`) para verificar "un callout por moneda base"
- [X] T019 [P] Crear `QuoteTestDataFactory` (`@IsTest`) en `FA/classes/QuoteTestDataFactory.cls` con `createOpportunity(Decimal amount, String currencyIsoCode)` y `createOpportunities(...)`, que insertan Oportunidades válidas (Name, StageName, CloseDate, Amount, CurrencyIsoCode). Documentar en un comentario que se usa **antes** de `Test.startTest()` o en `@TestSetup` (ver "Tests con callouts")
- [X] T020 [P] Crear `ExchangeRateClientTest` en `FA/classes/ExchangeRateClientTest.cls`, siguiendo "Tests con callouts". Debe cubrir: 200 con tasas; 404 → `isSupported = false`; 500 y 429 → `ExchangeRateUnavailableException`; timeout → `ExchangeRateUnavailableException`; body ilegible → excepción; dos monedas base → exactamente 2 callouts; la URL usa `callout:FrankfurterApi` (depende de T017, T018)
- [X] T021 [P] Crear `ErrorLoggerTest` en `FA/classes/ErrorLoggerTest.cls`. Debe verificar:
  - Se crea un `ErrorLog__c` con todos los campos.
  - Se puede loguear como un usuario sin permisos sobre `ErrorLog__c` (`System.runAs` de un usuario Standard User).
  - Con `businessMessage` de 5000 caracteres y `relatedRecordId` de 30 caracteres, **igual se crea** el `ErrorLog__c`, con los campos recortados.
  - Un fallo de insert no lanza excepción (depende de T011)
- [X] T022 (Se agregó además el permission set `FA/permissionsets/ErrorLogAdmin.permissionset-meta.xml` para que los administradores vean los campos del log.) Crear el permission set `OpportunityQuoteUser` (Label "Cotizador de Oportunidades - Uso", descripción en español) en `FA/permissionsets/OpportunityQuoteUser.permissionset-meta.xml`, con: Read sobre `Opportunity`, FLS de lectura sobre `Opportunity.Amount`, `objectPermissions` de `CurrencyQuote__c` con Create y Read (**sin** Edit ni Delete; los campos requeridos no llevan `fieldPermissions` porque la plataforma no los admite) y `externalCredentialPrincipalAccesses` para `FrankfurterNoAuth-FrankfurterPrincipal`. **Sin** permisos sobre `ErrorLog__c` (FR-024) (depende de T005, T010)
- [X] T023 Desplegar la fase y correr los tests: `sf project deploy start --source-dir force-app --target-org sdd-dev`, luego `sf apex run test --tests ExchangeRateClientTest ErrorLoggerTest --code-coverage --wait 10 --target-org sdd-dev`. Todos deben pasar

**Checkpoint**: la base está lista y se pueden empezar las historias.

---

## Phase 3: User Story 1 - Cotización solicitada por un sistema externo (Priority: P1) 🎯 MVP

**Goal**: `POST /services/apexrest/v1/opportunity-quotes` cotiza de 1 a 200 pedidos con "todo o nada", devuelve 200/400/500 según el contrato y guarda una `CurrencyQuote__c` por cada cotización exitosa (constitución, regla 12).

**Independent Test**: quickstart §4 (casos 4.1 a 4.8): la respuesta tiene los datos esperados; `convertedAmount` = `originalAmount × exchangeRate` truncado a 2 decimales; hay una `CurrencyQuote__c` (canal `ExternalSystem`) por cada éxito y ninguna por los rechazos.

### Implementation for User Story 1

- [X] T024 [US1] Crear `OpportunityQuoteService` en `FA/classes/OpportunityQuoteService.cls` con las constantes `CHANNEL_EXTERNAL = 'ExternalSystem'`, `CHANNEL_AGENT = 'Agent'` y `SOURCE = 'Cotizador de Oportunidades'`, y el método público `List<QuoteModels.QuoteResult> quote(List<QuoteModels.QuoteRequest> requests, String channel)`. En esta tarea implementar las **etapas 1 y 2** de research §3:
  - Etapa 1: lista null o vacía → `EMPTY_REQUEST_LIST`; más de `maxRequestsPerCall()` → `REQUEST_LIMIT_EXCEEDED`, con el máximo en el mensaje. Ambos cortan de inmediato, sin `requestIndex`.
  - Etapa 2, por pedido: Id vacío, mal formado o cuyo `getSObjectType()` no es `Opportunity` → `INVALID_OPPORTUNITY_ID`; moneda vacía o que no cumple `^[A-Za-z]{3}$` → `INVALID_CURRENCY_CODE`; normalizar la moneda a mayúsculas.
  - Cada error se guarda en un mapa posición → `QuoteException`, **sin cortar**. Los mensajes van en español, con el formato "Pedido N (Id X): …" del catálogo.
- [X] T025 [US1] En `FA/classes/OpportunityQuoteService.cls`, implementar la **etapa 3**: una sola consulta `SELECT Id, Amount, CurrencyIsoCode FROM Opportunity WHERE Id IN :ids WITH USER_MODE` sobre los Ids que pasaron la etapa 2. Id no devuelto → `OPPORTUNITY_NOT_FOUND` (mensaje "la Oportunidad indicada no existe", sin revelar si existe pero no es visible); `Amount == null` → `OPPORTUNITY_WITHOUT_AMOUNT` (depende de T024)
- [X] T026 [US1] En `FA/classes/OpportunityQuoteService.cls`, implementar las **etapas 4 y 5**:
  - Juntar las `CurrencyIsoCode` distintas de los pedidos que siguen sin error y llamar **una vez** a `ExchangeRateClient.getRates(bases)`.
  - `isSupported = false` → `UNSUPPORTED_CURRENCY` (mensaje sobre la moneda **original**). Moneda destino igual a la base → tasa 1. Moneda destino ausente de `rates` → `UNSUPPORTED_CURRENCY` (mensaje sobre la moneda **destino**). Ver FR-006.
  - Si `getRates` lanza `ExchangeRateUnavailableException`, asignar ese error (500) a **cada** pedido que llegó a esta etapa.
  - Cálculo: `convertedAmount = (amount * rate).setScale(2, System.RoundingMode.DOWN)`; `quotedAt = RateTable.fetchedAt`; `rateDate = RateTable.rateDate`. Armar la lista de `QuoteResult` en el **mismo orden** que los pedidos (depende de T025)
- [X] T027 [US1] En `FA/classes/OpportunityQuoteService.cls`, implementar la **selección y el log del error**:
  - Si hay errores, tomar el de **menor posición**, loguearlo con `ErrorLogger.log` (source `SOURCE`, el channel recibido, código, status, mensaje, detalle técnico, contexto "Pedido N de M, Id recibido: …") y relanzarlo.
  - `relatedRecordId` se completa **solo** si el Id del pedido es un Id válido de Salesforce; si no, se deja vacío, porque el valor crudo ya está en `context`.
  - Envolver todo el método en `try/catch (Exception e)`: toda excepción que no sea `QuoteException` se loguea como `INTERNAL_ERROR` (500) y se relanza como `QuoteException`, con el mensaje genérico del catálogo y el stack trace en `technicalDetail`.
  - Se crea **exactamente un** `ErrorLog__c` por llamada rechazada (SC-009) (depende de T026)
- [X] T028 [US1] En `FA/classes/OpportunityQuoteService.cls`, implementar la **etapa 6 (guardado)**:
  - Solo si no hubo ningún error, armar un `CurrencyQuote__c` por cada `QuoteResult` (Opportunity__c, OriginalAmount__c, OriginalCurrency__c, TargetCurrency__c, ExchangeRate__c, ConvertedAmount__c, QuotedAt__c, RateDate__c y `Channel__c` = channel) e insertarlos en **un solo** `Database.insert(records, AccessLevel.USER_MODE)`, después de todos los callouts (regla 5).
  - Un `DmlException` se trata como `INTERNAL_ERROR` (lo cubre el catch de T027). Si hubo error, no se inserta nada (FR-010, FR-018).
  - Ningún DML sobre `Opportunity` (FR-019) (depende de T027, T010)
- [X] T029 [US1] Crear `OpportunityQuoteResource` en `FA/classes/OpportunityQuoteResource.cls` (`@RestResource(urlMapping='/v1/opportunity-quotes')`, `global with sharing`, `@HttpPost global static void quote()`):
  - Deserializar `RestContext.request.requestBody` a `QuoteModels.BatchRequest`. Un `JSONException` o `requests == null` → `INVALID_REQUEST_BODY`, logueado con `ErrorLogger` (canal ExternalSystem) y respuesta 400.
  - Llamar a `OpportunityQuoteService.quote(requests, CHANNEL_EXTERNAL)`.
  - Si sale bien: status 200 y body `BatchResponse`. Si hay `QuoteException`: status = `httpStatus` y body `ErrorResponse`. Siempre `Content-Type: application/json`.
  - Nunca incluir `technicalDetail` en la respuesta (FR-008) (depende de T028)
- [X] T030 [US1] Agregar `classAccesses` para `OpportunityQuoteResource` en `FA/permissionsets/OpportunityQuoteUser.permissionset-meta.xml` (depende de T029)

### Tests for User Story 1

- [X] T031 [US1] Crear `OpportunityQuoteServiceTest` en `FA/classes/OpportunityQuoteServiceTest.cls`, siguiendo "Tests con callouts" (datos en `@TestSetup`, llamadas entre `Test.startTest()`/`Test.stopTest()`, `ExchangeRateCalloutMock` y `QuoteTestDataFactory`, nunca la API real). Debe cubrir:
  - Escenarios de aceptación: 10000 USD → EUR con tasa 0.87889 = 8788.90; lote de 3 en orden; Id inexistente; moneda destino no soportada (`XYZ`); moneda original no soportada (base 404, escenario 7); proveedor 500 y timeout; lote `[ok, Id inexistente, ok]` → `requestIndex` 2.
  - Casos borde: Amount null; moneda igual a la original → tasa 1; `eur` en minúsculas; `euro`; Id de otro objeto (por ejemplo, un Account); Id de 30 caracteres (el log se crea igual); lista vacía; 201 pedidos (con `OpportunityQuoteSettings.testOverride`); Id repetido → 2 resultados.
  - Truncado: un caso que termina en ,xx9 y otro con monto negativo.
  - Prioridad por posición: pedido 1 con Id inválido + proveedor caído → gana el 400 del pedido 1.
  - Un solo callout para 200 pedidos en USD (`callCount == 1`).
  - Guardado: cada éxito crea exactamente una `CurrencyQuote__c` con los 8 datos y el `Channel__c` recibido; un lote rechazado crea **0** `CurrencyQuote__c` (también para los pedidos válidos) y **1** `ErrorLog__c`; un éxito no crea ningún `ErrorLog__c`.
  - La Oportunidad conserva su Amount y CurrencyIsoCode (SC-004) (depende de T028, T018, T019)
- [X] T032 [US1] Crear `OpportunityQuoteResourceTest` en `FA/classes/OpportunityQuoteResourceTest.cls` usando `RestContext.request`/`response` y siguiendo "Tests con callouts". Debe cubrir:
  - 200 con el JSON exacto del contrato (nombres de propiedades, `quotedAt` ISO UTC).
  - 400 con `error.code`, `message`, `requestIndex`, `opportunityId`.
  - Body mal formado → 400 `INVALID_REQUEST_BODY`.
  - Proveedor caído → 500.
  - El body de error no contiene "Exception", "line" ni nombres de clase (SC-005).
  - Las cotizaciones creadas tienen `Channel__c = 'ExternalSystem'` (depende de T029)
- [X] T033 [US1] Desplegar y correr `sf apex run test --tests OpportunityQuoteServiceTest OpportunityQuoteResourceTest --code-coverage --wait 10 --target-org sdd-dev`. Después validar a mano con curl los casos 4.1 a 4.8 de [quickstart.md](./quickstart.md) y revisar que haya una `CurrencyQuote__c` por cada éxito y un `ErrorLog__c` por cada rechazo

**Checkpoint**: MVP funcional y alineado con la constitución. El sistema externo cotiza y cada cotización queda guardada.

---

## Phase 4: User Story 2 - Cotización conversando con el agente de Agentforce (Priority: P2)

**Goal**: un usuario interno le pide la cotización al agente en lenguaje natural y recibe los mismos datos y errores que el canal externo, usando el mismo Service.

**Independent Test**: quickstart §5 (casos 5.1 a 5.3). La respuesta del agente coincide con la del canal externo para el mismo Id, moneda y `rateDate` (SC-006).

### Implementation for User Story 2

- [X] T034 [US2] Crear `OpportunityQuoteAction` en `FA/classes/OpportunityQuoteAction.cls` según [contracts/agent-action.md](./contracts/agent-action.md):
  - `@InvocableMethod(label='Cotizar Oportunidad en otra moneda' description='…en español…')` que recibe `List<Request>` (`opportunityId`, `targetCurrency`, ambas `@InvocableVariable(required=true)` con label y descripción en español) y devuelve `List<Response>` (`isSuccess`, `message`, `errorCode`, `originalAmount`, `originalCurrency`, `targetCurrency`, `exchangeRate`, `convertedAmount`, `quotedAt` como String ISO 8601 UTC).
  - Convierte los Requests a `QuoteModels.QuoteRequest` y llama **una vez** a `OpportunityQuoteService.quote(..., CHANNEL_AGENT)` (regla 14: sin lógica duplicada).
  - Si sale bien: `message` es un resumen en español con los 6 datos. Si hay `QuoteException`: devuelve `isSuccess = false` con el mensaje de negocio y el código **para cada** Request, y nunca lanza la excepción
- [X] T035 [US2] Agregar `classAccesses` para `OpportunityQuoteAction` en `FA/permissionsets/OpportunityQuoteUser.permissionset-meta.xml` (depende de T034)
- [X] T036 [US2] Crear `OpportunityQuoteActionTest` en `FA/classes/OpportunityQuoteActionTest.cls`, siguiendo "Tests con callouts". Debe cubrir:
  - Éxito con los 6 datos y un `message` que los contiene.
  - Id inexistente → `isSuccess = false` y el mismo mensaje que devolvería el Service.
  - Proveedor caído → `isSuccess = false` sin valores numéricos.
  - Los valores son idénticos a los del Service para el mismo mock (SC-006).
  - La `CurrencyQuote__c` creada tiene `Channel__c = 'Agent'` y el `ErrorLog__c` de un rechazo tiene `Channel__c = 'Agent'` (depende de T034)
- [X] T037 [US2] Desplegar y correr `sf apex run test --tests OpportunityQuoteActionTest --code-coverage --wait 10 --target-org sdd-dev`
- [ ] T038 [US2] **(Manual en la UI de Salesforce)** En Agentforce Builder, crear la Agent Action de tipo Apex sobre `OpportunityQuoteAction` y el Topic "Cotización de Oportunidades" con la descripción y las 4 instrucciones de [contracts/agent-action.md](./contracts/agent-action.md). Marcar las entradas como "Require Input" y las salidas como "Show in conversation", agregar el topic al Agentforce Employee Agent y activarlo. Asignar `OpportunityQuoteUser` a los usuarios internos que van a usar el agente
- [ ] T039 [US2] Recuperar la metadata del agente al repo: `sf project retrieve start --metadata GenAiFunction GenAiPlugin GenAiPlannerBundle --target-org sdd-dev`. Queda en `FA/genAiFunctions/`, `FA/genAiPlugins/` y `FA/genAiPlannerBundles/`. Revisar que solo se agreguen la acción, el topic y el agente que usamos, y descartar lo demás (depende de T038)
- [ ] T040 [US2] Validar los casos 5.1 a 5.3 de [quickstart.md](./quickstart.md) en el panel de Agentforce, comparando 5.1 con una llamada curl hecha en el mismo momento

**Checkpoint**: los dos canales cotizan con la misma lógica.

---

## Phase 5: User Story 3 - Registro histórico de cotizaciones para auditoría (Priority: P3)

**Goal**: el auditor consulta el historial en Salesforce (solo lectura) y el historial no se puede perder: no se puede borrar una Oportunidad con cotizaciones y cada cotización es un registro independiente.

**Independent Test**: quickstart §6: el auditor ve las cotizaciones en la related list de la Oportunidad y no puede editarlas; el borrado de una Oportunidad con cotizaciones está bloqueado; 3 cotizaciones dan 3 registros.

### Implementation for User Story 3

- [X] T041 [P] [US3] Crear el permission set `CurrencyQuoteAuditor` (Label "Cotizaciones de Moneda - Auditoría", descripción en español) en `FA/permissionsets/CurrencyQuoteAuditor.permissionset-meta.xml`, con solo Read sobre `CurrencyQuote__c` (FR-020)
- [X] T042 [P] [US3] Recuperar el layout de Oportunidad (`sf project retrieve start --metadata "Layout:Opportunity-Opportunity Layout" --target-org sdd-dev`) y agregar la related list `CurrencyQuotes` con las columnas Name, `TargetCurrency__c`, `ExchangeRate__c`, `ConvertedAmount__c`, `QuotedAt__c` y `Channel__c` en `FA/layouts/Opportunity-Opportunity Layout.layout-meta.xml`. Crear además `FA/layouts/CurrencyQuote__c-Cotización de Moneda Layout.layout-meta.xml` con todos los campos en solo lectura

### Tests for User Story 3

- [X] T043 [US3] Crear `CurrencyQuoteAuditTest` en `FA/classes/CurrencyQuoteAuditTest.cls`, siguiendo "Tests con callouts". Debe cubrir:
  - 3 cotizaciones de la misma Oportunidad → 3 registros independientes.
  - Borrar una Oportunidad con cotizaciones → `DmlException` (FR-020a).
  - Un usuario con solo `CurrencyQuoteAuditor` (`System.runAs`) puede leer las cotizaciones y **no** puede actualizarlas ni borrarlas.
  - Ese usuario no puede leer `ErrorLog__c` (FR-024) (depende de T041)
- [X] T044 [US3] Desplegar, correr `sf apex run test --tests CurrencyQuoteAuditTest --code-coverage --wait 10 --target-org sdd-dev` y validar [quickstart.md](./quickstart.md) §6: consultas SOQL, intento de borrado desde la UI y vista del auditor

**Checkpoint**: las tres historias funcionan y se pueden probar por separado.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T045 Correr la suite completa con cobertura: `sf apex run test --code-coverage --result-format human --wait 15 --target-org sdd-dev --tests OpportunityQuoteServiceTest OpportunityQuoteResourceTest OpportunityQuoteActionTest ExchangeRateClientTest ErrorLoggerTest CurrencyQuoteAuditTest`. Cada clase del feature debe tener **≥ 85%** de cobertura (regla 13). Si alguna no llega, agregar tests
- [X] T046 [P] Revisar todas las clases de `FA/classes/` contra el checklist de [quickstart.md](./quickstart.md): `with sharing`, comentarios para no programadores, sin SOQL/DML en loops, callouts antes del DML, sin hardcodeo. Corregir lo que falte
- [X] T047 [P] Revisar que todo objeto y campo de `FA/objects/` tenga Label y `<description>` en español (reglas 1 y 2)
- [X] T048 [P] Actualizar `salesforce-sdd-integration/manifest/package.xml` con los tipos nuevos: ApexClass, CustomObject, CustomField, CustomMetadata, ExternalCredential, NamedCredential, PermissionSet, Layout, GenAiFunction, GenAiPlugin y GenAiPlannerBundle
- [X] T049 [P] Agregar a `salesforce-sdd-integration/README.md` una sección "Cotizador de Oportunidades" con el endpoint, un ejemplo de curl y un link a [quickstart.md](./quickstart.md)
- [X] T050 Ejecutar [quickstart.md](./quickstart.md) completo de punta a punta y medir el tiempo de respuesta de 10 llamadas de un pedido (SC-001: p95 < 3 s) y de una llamada con 200 pedidos (SC-008)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: sin dependencias.
- **Foundational (Phase 2)**: depende de Setup y **bloquea** todas las historias. Incluye los dos objetos de datos (`ErrorLog__c`, `CurrencyQuote__c`).
- **US1 (Phase 3)**: depende de Foundational. Es el MVP y ya guarda las cotizaciones (regla 12).
- **US2 (Phase 4)**: depende de US1, porque reutiliza `OpportunityQuoteService` (FR-015).
- **US3 (Phase 5)**: depende de US1, porque sus tests generan cotizaciones con el Service. Es **independiente de US2**, así que se pueden hacer en cualquier orden o en paralelo.
- **Polish (Phase 6)**: depende de las historias que se quieran entregar.

```text
Setup → Foundational → US1 (MVP) ─┬─→ US2 (agente)
                                  └─→ US3 (auditoría)
                                         └→ Polish
```

### Within Each Phase

- Metadata (objetos y campos) → clases que la usan → tests → deploy + validación.
- Las tareas sobre `OpportunityQuoteService.cls` (T024 a T028) y sobre `OpportunityQuoteUser.permissionset-meta.xml` (T022, T030, T035) son **secuenciales**, porque editan el mismo archivo.

### Parallel Opportunities

- **Foundational**: T003, T005, T007 a T010, T012, T015, T016, T018 y T019 son independientes entre sí. T013 y T014 van en paralelo después de T012. T020 y T021 van en paralelo al final.
- **US2 ∥ US3**: después de US1 se pueden hacer en paralelo. T041 y T042 no tocan clases.
- **Polish**: T046 a T049 en paralelo.

## Parallel Example: Foundational

```text
En paralelo (archivos distintos, sin dependencias):
  T003 OpportunityQuoteSetting__mdt
  T005 External Credential FrankfurterNoAuth (+ deploy de prueba)
  T007 + T008 ErrorLog__c y sus campos
  T009 + T010 CurrencyQuote__c y sus campos
  T012 QuoteException
  T015 QuoteModels
  T016 OpportunityQuoteSettings
  T018 ExchangeRateCalloutMock
  T019 QuoteTestDataFactory
Después: T004, T006, T011, T013, T014 → T017 → T020, T021 → T022 → T023
```

## Parallel Example: User Story 3

```text
En paralelo: T041 permission set de auditor + T042 layouts
Después: T043 (tests) → T044 (deploy + quickstart §6)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2: la base (config, credencial, objetos, log, cliente del proveedor).
2. Phase 3: el endpoint REST cotiza con "todo o nada" y guarda cada cotización.
3. **Parar y validar**: tests + quickstart §4. Ya se le puede mostrar al "cliente" (el ERP).
4. Commit + push.

### Incremental Delivery

1. MVP (US1) → commit.
2. US3 (auditoría: permisos, layouts, bloqueo de borrado) → commit. Es chica y no requiere la UI de Agentforce.
3. US2 (agente) → commit.
4. Polish → commit → PR a `main`.

---

## Notes

- [P] = archivos distintos y sin dependencias pendientes.
- Cada historia cierra con deploy y tests en verde antes de seguir.
- Commit al final de cada fase (ver [quickstart.md](./quickstart.md) para validar).
- T038 es la única tarea manual en la UI. Lo demás es metadata versionada.
