import Testing
@testable import YTMCore

@Suite struct ProxyTests {
    private func address(_ text: String) -> String? {
        try? Proxy.parse(text).shown
    }

    private func refusal(_ text: String) -> String? {
        do throws(YTMError) {
            _ = try Proxy.parse(text)
            return nil
        } catch {
            return error.message
        }
    }

    @Test func takesProxyAddressesWithAHostAndPort() {
        #expect(address("127.0.0.1:8080") == "http://127.0.0.1:8080")
        #expect(address(" socks5h://user:secret@proxy.example:1080 ") == "socks5h://proxy.example:1080", "no password shown")
        #expect(address("https://[::1]:3128") == "https://[::1]:3128")
        #expect(address("http://proxy") == "http://proxy:80")
        #expect(address("HTTPS://Proxy.Example") == "https://proxy.example:443")
        #expect(address("http://prøxy.lan:8080") == "http://xn--prxy-hra.lan:8080", "punycode, as on Windows")
    }

    @Test func refusesOthersWithWindowsWords() {
        let notAnAddress = "That isn't a proxy address, like http://127.0.0.1:8080."
        #expect(refusal("ftp://proxy:21") == "Use an http:// or socks5:// address.")
        #expect(refusal("socks5://proxy") == "The address needs a port, like :1080.", "no port to assume")
        #expect(refusal("socks5://") == "The address needs a host.")
        #expect(refusal(":8080") == notAnAddress, "an empty host is no address")
        #expect(refusal("ftp://:21") == notAnAddress)
        #expect(refusal("http://:8080") == notAnAddress)
        #expect(refusal("socks5://user@") == "That isn't a proxy address. Write @, # or / in a user name or password as %40, %23 or %2F.")
        #expect(refusal("not a proxy") == notAnAddress)
        #expect(refusal("socks5://prøxy.lan") == "The address needs a port, like :1080.")
        #expect(refusal("socks5://prøxy.lan:1080") == notAnAddress, "not a URI")
        #expect(refusal("socks5://pr%C3%B8xy.lan:1080") == notAnAddress)
        #expect(refusal("http://proxy:65536") == notAnAddress)
    }

    @Test func keepsTheCredentialsForTheConnectionOnly() throws {
        let proxy = try Proxy.parse("socks5://user:se%40cret@127.0.0.1:1080")
        #expect(proxy.user == "user")
        #expect(proxy.password == "se@cret")
        #expect(!proxy.shown.contains("secret"))
        #expect(proxy != (try Proxy.parse("socks5://127.0.0.1:1080")), "a new password is a change")
        let unencoded = try Proxy.parse("http://me:p@ss word@10.0.0.1:3128")
        #expect(unencoded.user == "me")
        #expect(unencoded.password == "p@ss word", "encoded as Windows does")
        #expect(unencoded.shown == "http://10.0.0.1:3128")
        #expect(refusal("http://user:pa#ss@proxy:8080")?.contains("%23") == true, "says how to write a password's #")
        #expect(try Proxy.parse("http://user:pa%23ss@proxy:8080").password == "pa#ss")
    }
}
