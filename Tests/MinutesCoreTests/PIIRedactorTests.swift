import Testing

@testable import MinutesCore

@Suite struct PIIRedactorTests {
    let redactor = PIIRedactor()

    @Test(arguments: [
        ("Email me at jane.doe@example.com today.", "Email me at [EMAIL] today."),
        ("It's john dot smith at gmail dot com.", "It's [EMAIL]."),
        ("My email is jane.doatexample.com.", "My email is [EMAIL]."),
        ("Send it to jane.doe at example.com please.", "Send it to [EMAIL] please."),
    ])
    func emails(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test(arguments: [
        ("Call me at 415-555-0132 if anything is unclear.", "Call me at [PHONE] if anything is unclear."),
        ("Call me at 415. 555, 0132 if anything is unclear.", "Call me at [PHONE] if anything is unclear."),
        ("Try (415) 555-0132.", "Try [PHONE]."),
        ("It's five five five, one two one, two three four five.", "It's [PHONE]."),
        ("Dial 4 1 5 5 5 5 0 1 3 2 now.", "Dial [PHONE] now."),
    ])
    func phones(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test func governmentIDsCardsAndAccounts() {
        #expect(redactor.redact("My social is 123-45-6789.") == "My social is [ID].")
        #expect(redactor.redact("Card 4111 1111 1111 1111 expires soon.") == "Card [CARD] expires soon.")
        // Fails the Luhn check, so it's not a card, but a long digit run is still an account number.
        #expect(redactor.redact("Reference 4111111111111112 please.") == "Reference [ACCOUNT] please.")
        #expect(redactor.redact("The server is 10.0.1.25.") == "The server is [IP].")
    }

    @Test func names() {
        #expect(
            redactor.redact("I spoke with Marcus Chen about the budget.")
                == "I spoke with [NAME] about the budget.")
        // Missed by the recognizer in this context; the lexicon catches it.
        #expect(
            redactor.redact("I sent the agenda to Priya yesterday afternoon.")
                == "I sent the agenda to [NAME] yesterday afternoon.")
        // Lowercase names that aren't everyday words.
        #expect(redactor.redact("okay so dave said it's fine") == "okay so [NAME] said it's fine")
        // Sentence-initial names.
        #expect(redactor.redact("Priya, can you take this one?") == "[NAME], can you take this one?")
    }

    @Test func keepsCompaniesAndProducts() {
        let untouched = [
            "We use Stripe and Plaid for payments.",
            "We should move our payments over to Stripe next quarter.",
            "Apple and Dell both quoted for the laptops.",
            "The Tesla fleet contract renews in March.",
            "We rewrote the importer in Ruby last year.",
            "Our Chase account covers payroll.",
        ]
        for text in untouched {
            #expect(redactor.redact(text) == text)
        }
        // People are still found around them.
        #expect(redactor.redact("Priya from Stripe will join the call.") == "[NAME] from Stripe will join the call.")
        #expect(redactor.redact("I met Dr. Okonkwo at Stripe.") == "I met Dr. [NAME] at Stripe.")
    }

    @Test func wordsToKeepAreNeverNames() {
        let keeping = PIIRedactor(keep: ["Priya", "wells fargo"])
        #expect(keeping.redact("Priya from Wells Fargo will join.") == "Priya from Wells Fargo will join.")
        #expect(keeping.redact("Marcus will join.") == "[NAME] will join.")
        #expect(keeping.redact("Email priya@example.com") == "Email [EMAIL]")  // only names are kept
    }

    @Test func keepsEverydayWordsPlacesAndNumbers() {
        let untouched = [
            "Will you send the deck by May?",
            "We need a decision by next week at the latest.",
            "The Austin office grew 10% to 1,250 people in 2025.",
            "Revenue was 10,000,000 dollars.",
            "Let's meet on Thursday at 3 pm.",
            "Grace period ends in June.",
        ]
        for text in untouched {
            #expect(redactor.redact(text) == text)
        }
    }

    @Test func respectsCategories() {
        let emailsOnly = PIIRedactor(categories: [.email])
        #expect(
            emailsOnly.redact("Priya is at priya@example.com.") == "Priya is at [EMAIL].")
        #expect(PIIRedactor(categories: []).redact("Priya") == "Priya")
    }

    @Test func luhn() {
        #expect(PIIRedactor.luhnValid("4111 1111 1111 1111"))
        #expect(!PIIRedactor.luhnValid("4111 1111 1111 1112"))
    }
}
