/**
 * ErrorLoggerTest
 *
 * Qué prueba: que ErrorLogger guarda el log con todos sus datos, que funciona aunque el usuario no
 * tenga permisos sobre el log, que recorta los textos demasiado largos y que nunca lanza excepciones.
 */
@IsTest
private with sharing class ErrorLoggerTest {

    @IsTest
    static void guardaUnLogConTodosLosDatos() {
        ErrorLogger.Entry entry = sampleEntry();

        Test.startTest();
        ErrorLogger.log(entry);
        Test.stopTest();

        ErrorLog__c log = [
            SELECT OccurredAt__c, Source__c, Channel__c, ErrorCode__c, StatusCode__c, BusinessMessage__c,
                   TechnicalDetail__c, RelatedRecordId__c, Context__c
            FROM ErrorLog__c
            WITH SYSTEM_MODE
        ];
        Assert.isNotNull(log.OccurredAt__c, 'Fecha/hora');
        Assert.areEqual('Funcionalidad de prueba', log.Source__c, 'Funcionalidad de origen');
        Assert.areEqual('ExternalSystem', log.Channel__c, 'Canal');
        Assert.areEqual('OPPORTUNITY_NOT_FOUND', log.ErrorCode__c, 'Código');
        Assert.areEqual(400, log.StatusCode__c, 'Código HTTP');
        Assert.areEqual('La Oportunidad indicada no existe.', log.BusinessMessage__c, 'Mensaje de negocio');
        Assert.areEqual('Detalle técnico', log.TechnicalDetail__c, 'Detalle técnico');
        Assert.areEqual('006000000000000AAA', log.RelatedRecordId__c, 'Id relacionado');
        Assert.areEqual('Pedido 1 de 1', log.Context__c, 'Contexto');
    }

    @IsTest
    static void unUsuarioSinPermisosSobreElLogIgualPuedeRegistrarErrores() {
        User standardUser = QuoteTestDataFactory.createUser('Standard User', null);

        Test.startTest();
        System.runAs(standardUser) {
            ErrorLogger.log(sampleEntry());
        }
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM ErrorLog__c], 'El log se guarda en modo sistema');
    }

    @IsTest
    static void recortaLosTextosDemasiadoLargosEnLugarDePerderElLog() {
        ErrorLogger.Entry entry = sampleEntry();
        entry.businessMessage = 'x'.repeat(5000);
        entry.relatedRecordId = 'y'.repeat(30);

        Test.startTest();
        ErrorLogger.log(entry);
        Test.stopTest();

        ErrorLog__c log = [SELECT BusinessMessage__c, RelatedRecordId__c FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.areEqual(2000, log.BusinessMessage__c.length(), 'El mensaje se recorta a 2000');
        Assert.areEqual(18, log.RelatedRecordId__c.length(), 'El Id se recorta a 18');
    }

    @IsTest
    static void completaLosCamposObligatoriosVacios() {
        Test.startTest();
        ErrorLogger.log(new ErrorLogger.Entry());
        Test.stopTest();

        ErrorLog__c log = [SELECT Source__c, ErrorCode__c, BusinessMessage__c FROM ErrorLog__c WITH SYSTEM_MODE];
        Assert.areEqual('Desconocido', log.Source__c, 'Funcionalidad por defecto');
        Assert.areEqual('Desconocido', log.ErrorCode__c, 'Código por defecto');
        Assert.areEqual('Desconocido', log.BusinessMessage__c, 'Mensaje por defecto');
    }

    @IsTest
    static void ignoraListasVaciasYEntradasNulas() {
        Test.startTest();
        ErrorLogger.log(new List<ErrorLogger.Entry>());
        ErrorLogger.log((List<ErrorLogger.Entry>) null);
        ErrorLogger.log(new List<ErrorLogger.Entry>{ null });
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ErrorLog__c], 'No hay nada que registrar');
    }

    @IsTest
    static void noLanzaExcepcionesSiElInsertFalla() {
        ErrorLogger.Entry entry = sampleEntry();
        entry.statusCode = 99999; // No entra en Number(3,0): el insert falla

        Test.startTest();
        ErrorLogger.log(entry); // No debe lanzar excepción
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ErrorLog__c], 'El insert falló pero sin romper al llamador');
    }

    private static ErrorLogger.Entry sampleEntry() {
        ErrorLogger.Entry entry = new ErrorLogger.Entry();
        entry.source = 'Funcionalidad de prueba';
        entry.channel = 'ExternalSystem';
        entry.errorCode = 'OPPORTUNITY_NOT_FOUND';
        entry.statusCode = 400;
        entry.businessMessage = 'La Oportunidad indicada no existe.';
        entry.technicalDetail = 'Detalle técnico';
        entry.relatedRecordId = '006000000000000AAA';
        entry.context = 'Pedido 1 de 1';
        return entry;
    }
}
