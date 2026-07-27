import Testing
@testable import OtegamiCore

@Suite("FreeMailDomains")
struct FreeMailDomainsTests {
    @Test("gmail.com is a free mail domain")
    func gmailIsFreeMail() {
        #expect(FreeMailDomains.isFreeMailDomain("gmail.com"))
        #expect(!FreeMailDomains.isEligibleForCompanyLogo(domain: "gmail.com"))
    }

    @Test("major international and Japanese free providers are recognized")
    func otherKnownFreeProviders() {
        for domain in ["icloud.com", "yahoo.co.jp", "outlook.com", "docomo.ne.jp", "qq.com"] {
            #expect(FreeMailDomains.isFreeMailDomain(domain), "\(domain) should be recognized as free mail")
        }
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(FreeMailDomains.isFreeMailDomain("Gmail.COM"))
    }

    @Test("a real company domain is eligible for a company logo")
    func companyDomainIsEligible() {
        #expect(!FreeMailDomains.isFreeMailDomain("apple.com"))
        #expect(FreeMailDomains.isEligibleForCompanyLogo(domain: "apple.com"))
    }

    @Test("otegami.test (dev mailstack fixture domain) is eligible")
    func devFixtureDomainIsEligible() {
        #expect(FreeMailDomains.isEligibleForCompanyLogo(domain: "otegami.test"))
    }
}
