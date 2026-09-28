# Implementation Plan: Cotizador de Oportunidades

**Branch**: `001-opportunity-currency-quote` | **Date**: 2026-09-28 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-opportunity-currency-quote/spec.md`

## Summary

Un sistema externo envía por POST una lista de pedidos (Id de Oportunidad + moneda destino) a un
endpoint Apex REST, y un usuario interno pide lo mismo al agente de Agentforce. Ambos canales son
"adaptadores" delgados que llaman a **una única clase Service** (`OpportunityQuoteService`). El
Service valida todos los pedidos, lee las Oportunidades con una sola consulta, obtiene los tipos de
cambio de **Frankfurter** con **un callout por moneda base distinta** (no uno por pedido), calcula
el monto convertido truncado a 2 decimales y, solo si todos los pedidos salieron bien, inserta los
registros `CurrencyQuote__c` en un único DML. Si algo falla, no se inserta ninguna cotización, se
guarda un registro en el log genérico `ErrorLog__c` y el adaptador traduce el error a HTTP 400/500
(canal externo) o a un mensaje claro (agente).

## Technical Context

**Language/Version**: Apex, API 67.0 (`sourceApiVersion` de `sfdx-project.json`)

**Primary Dependencies**: Salesforce Platform (Apex REST, Invocable Actions, Named/External
Credentials, Custom Metadata Types), Agentforce (Agent Actions + Topics), API externa Frankfurter
(`https://api.frankfurter.dev/v1`)

**Storage**: Objetos custom de Salesforce: `CurrencyQuote__c` (historial), `ErrorLog__c` (log
genérico); Custom Metadata `OpportunityQuoteSetting__mdt` (configuración)

**Testing**: Apex tests (`@IsTest`) con `HttpCalloutMock`; ejecución con `sf apex run test`;
cobertura mínima 85% (constitución, regla 13)

**Target Platform**: Org de desarrollo `sdd-dev` con Multi-Currency habilitado y Agentforce
disponible

**Project Type**: Proyecto Salesforce DX (metadata en `salesforce-sdd-integration/force-app`)

**Performance Goals**: p95 < 3 s para un pedido individual (SC-001); 200 pedidos por llamada sin
fallar por volumen (SC-008)

**Constraints**: Governor limits por transacción: 100 SOQL, 150 DML, 100 callouts, 120 s de
tiempo acumulado de callouts; callout antes de cualquier DML (regla 5); timeout del proveedor
10 s (configurable)

**Scale/Scope**: Hasta 200 pedidos por llamada; en la práctica 1 SOQL + 1 callout por moneda base
distinta (limitado por las monedas activas de la org) + 1 DML de cotizaciones + a lo sumo 1 DML de
log

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Regla | Cómo la cumple el diseño | Estado |
|---|-------|--------------------------|--------|
| 1 | API Names en inglés, Labels en español | `CurrencyQuote__c` "Cotización de Moneda", `ErrorLog__c` "Log de Errores", campos en inglés con label en español ([data-model.md](./data-model.md)) | ✅ |
| 2 | Descripción en español en todo objeto/campo | Cada objeto y campo del data model lleva descripción | ✅ |
| 3 | Triggers delegan a Handler | No se necesita trigger: el bloqueo de borrado lo hace la relación Lookup (`deleteConstraint = Restrict`) | ✅ N/A |
| 4 | Tres capas: REST / Service / integración | `OpportunityQuoteResource` (HTTP) → `OpportunityQuoteService` (negocio) → `ExchangeRateClient` (callout) | ✅ |
| 5 | Callout antes de DML | El Service hace todos los callouts, y recién al final inserta cotizaciones y/o log | ✅ |
| 6 | Sin SOQL/DML en loops, bulkificado | 1 SOQL con `IN :ids`, callouts agrupados por moneda base, 1 `insert` de lista | ✅ |
| 7 | Wrappers tipados para REST | `QuoteModels` (clases internas `QuoteRequest`, `QuoteResult`, `BatchRequest`, `BatchResponse`, `ErrorResponse`) | ✅ |
| 8 | Excepciones propias del dominio | `QuoteException` (base) → `QuoteValidationException` (400), `ExchangeRateUnavailableException` (500); cualquier excepción inesperada se envuelve como `INTERNAL_ERROR` | ✅ |
| 9 | Todas las clases `with sharing` | Todas declaran `with sharing`; el SOQL usa `WITH USER_MODE` | ✅ |
| 10 | Nada hardcodeado | Endpoint en Named Credential `FrankfurterApi`; máximo de pedidos y timeout en `OpportunityQuoteSetting__mdt` | ✅ |
| 11 | Trabajo secundario en Queueable | No hay trabajo secundario en v1 (el log de errores es parte de la respuesta, no una notificación) | ✅ N/A |
| 12 | Nunca modificar la Oportunidad | Solo se lee; no hay ningún DML sobre `Opportunity` | ✅ |
| 13 | Tests ≥ 85% con `HttpCalloutMock` | `ExchangeRateCalloutMock` configurable; ningún test llama a la API real | ✅ |
| 14 | Agentforce reutiliza el Service | `OpportunityQuoteAction` solo adapta entrada/salida y llama a `OpportunityQuoteService` | ✅ |
| 15 | Comentarios para no programadores | Convención obligatoria en todas las clases (ver quickstart, checklist de revisión) | ✅ |
| 16 | Simple por sobre elegante | Sin frameworks, sin patrones extra (no selector/domain layer, no fflib) | ✅ |

**Resultado del gate (pre-research)**: PASA, sin violaciones.
**Re-chequeo post-diseño (Phase 1)**: PASA. El único punto sensible es la inserción de
`ErrorLog__c` en `AccessLevel.SYSTEM_MODE` (ver [research.md](./research.md) §6): no viola la regla
9, porque la clase sigue siendo `with sharing`; solo evita que los usuarios de negocio necesiten
permiso sobre el log (FR-024).

## Project Structure

### Documentation (this feature)

```text
specs/001-opportunity-currency-quote/
├── plan.md              # Este archivo
├── research.md          # Phase 0: decisiones técnicas
├── data-model.md        # Phase 1: objetos, campos, CMDT, permisos
├── quickstart.md        # Phase 1: guía de validación end-to-end
├── contracts/
│   ├── opportunity-quotes-api.md        # Contrato REST (canal externo)
│   ├── opportunity-quotes.openapi.yaml  # Mismo contrato en formato OpenAPI 3
│   └── agent-action.md                  # Contrato de la Agent Action (canal agente)
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks, NO lo crea este comando)
```

### Source Code (repository root)

```text
salesforce-sdd-integration/force-app/main/default/
├── classes/
│   ├── OpportunityQuoteResource.cls        # Capa REST: POST /v1/opportunity-quotes
│   ├── OpportunityQuoteAction.cls          # Adaptador Agentforce (@InvocableMethod)
│   ├── OpportunityQuoteService.cls         # Lógica de negocio única (ambos canales)
│   ├── ExchangeRateClient.cls              # Único punto de callout a Frankfurter
│   ├── QuoteModels.cls                     # Wrappers tipados de request/response
│   ├── QuoteException.cls                  # Excepción base del dominio (virtual)
│   ├── QuoteValidationException.cls        # Errores de pedido (400)
│   ├── ExchangeRateUnavailableException.cls# Proveedor caído/timeout/error (500)
│   ├── ErrorLogger.cls                     # Log genérico reutilizable → ErrorLog__c
│   ├── OpportunityQuoteSettings.cls        # Lee OpportunityQuoteSetting__mdt
│   └── tests: OpportunityQuoteResourceTest, OpportunityQuoteActionTest,
│       OpportunityQuoteServiceTest, ExchangeRateClientTest, ErrorLoggerTest,
│       ExchangeRateCalloutMock, QuoteTestDataFactory
├── objects/
│   ├── CurrencyQuote__c/  (object + fields/)
│   ├── ErrorLog__c/       (object + fields/)
│   └── OpportunityQuoteSetting__mdt/ (object + fields/)
├── customMetadata/OpportunityQuoteSetting.Default.md-meta.xml
├── externalCredentials/FrankfurterNoAuth.externalCredential-meta.xml
├── namedCredentials/FrankfurterApi.namedCredential-meta.xml
├── permissionsets/
│   ├── OpportunityQuoteUser.permissionset-meta.xml    # Integración + usuarios del agente
│   └── CurrencyQuoteAuditor.permissionset-meta.xml    # Solo lectura del historial
└── genAiFunctions/, genAiPlugins/ # Agent Action y Topic (se configuran en Agentforce
                                    # Builder y se recuperan con `sf project retrieve`)
```

**Structure Decision**: Proyecto Salesforce DX único. El proyecto SFDX vive en la subcarpeta
`salesforce-sdd-integration/` del repo (ahí está `sfdx-project.json`), por lo que toda la metadata
va bajo `salesforce-sdd-integration/force-app/main/default/`. Los tests Apex conviven con las
clases en `classes/` (convención estándar de Salesforce).

## Complexity Tracking

No hay violaciones de la constitución que justificar.
