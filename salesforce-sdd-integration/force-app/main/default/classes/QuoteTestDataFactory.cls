/**
 * QuoteTestDataFactory
 *
 * Qué hace: crea datos de prueba (Oportunidades y usuarios) para los tests del Cotizador.
 *
 * Por qué existe: para no repetir en cada test cómo se arma una Oportunidad válida.
 *
 * IMPORTANTE (Tests con callouts): estos métodos hacen DML (insert). En Apex no se puede hacer un
 * callout después de un DML en la misma transacción, así que hay que usarlos en @TestSetup o ANTES
 * de Test.startTest(), y hacer la llamada al Service entre Test.startTest() y Test.stopTest().
 */
@IsTest
public with sharing class QuoteTestDataFactory {

    /** Crea e inserta una Oportunidad con el monto y la moneda indicados. */
    public static Opportunity createOpportunity(Decimal amount, String currencyIsoCode) {
        return createOpportunities(1, amount, currencyIsoCode)[0];
    }

    /** Crea e inserta varias Oportunidades iguales (con un solo insert). */
    public static List<Opportunity> createOpportunities(Integer count, Decimal amount, String currencyIsoCode) {
        List<Opportunity> opportunities = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opportunities.add(new Opportunity(
                Name = 'Oportunidad de prueba ' + i,
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(30),
                Amount = amount,
                CurrencyIsoCode = currencyIsoCode
            ));
        }
        insert opportunities;
        return opportunities;
    }

    /**
     * Crea e inserta un usuario de prueba con el perfil indicado y le asigna los permission sets.
     * Se usa con System.runAs para probar qué puede y qué no puede hacer cada tipo de usuario.
     *
     * Los usuarios y sus permisos son objetos "de configuración" (setup). Salesforce no permite
     * mezclarlos con datos de negocio en la misma transacción (error MIXED_DML_OPERATION), así que
     * los creamos dentro de System.runAs, que en los tests los aísla en su propio contexto.
     */
    public static User createUser(String profileName, List<String> permissionSetNames) {
        User created;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            created = insertUser(profileName, permissionSetNames);
        }
        return created;
    }

    private static User insertUser(String profileName, List<String> permissionSetNames) {
        Profile profile = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1];
        String uniqueKey = String.valueOf(Crypto.getRandomInteger()).replace('-', '');
        User user = new User(
            ProfileId = profile.Id,
            LastName = 'Prueba ' + uniqueKey,
            Email = 'cotizador.test' + uniqueKey + '@example.com',
            Username = 'cotizador.test' + uniqueKey + '@example.com.sdd',
            Alias = uniqueKey.left(8),
            TimeZoneSidKey = 'America/Argentina/Buenos_Aires',
            LocaleSidKey = 'es_AR',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            DefaultCurrencyIsoCode = 'USD'
        );
        insert user;

        if (permissionSetNames != null && !permissionSetNames.isEmpty()) {
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = user.Id, PermissionSetId = permissionSet.Id));
            }
            insert assignments;
        }
        return user;
    }
}
