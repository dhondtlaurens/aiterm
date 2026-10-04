// app/Tests/AiTermCoreTests/SleepRuleTests.swift
import Testing
@testable import AiTermCore

@Suite struct SleepRuleTests {
    @Test func theRuleAllowsExactlyTheTwoPmsetCommandsForTheUser() throws {
        let text = try #require(SleepRule.text(user: "laurensdhondt"))
        #expect(text == """
            # Installed by AiTerm for Backpack Mode. Remove with Settings > Backpack > Remove Setup.
            laurensdhondt ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

            """)
        #expect(!text.contains("ALL=(ALL)") && !text.contains("*"))
    }

    @Test func unsafeUserNamesGetNoRule() {
        for user in ["", "-root", "two words", "DOMAIN\\me", "me,root", "me\nroot ALL=(ALL) ALL", "jürgen"] {
            #expect(SleepRule.text(user: user) == nil, "\(user)")
            #expect(SleepRule.installCommand(user: user) == nil, "\(user)")
        }
        #expect(SleepRule.text(user: "first.last-2_x") != nil)
    }

    /// Validated before it is installed, installed root:wheel 0440, and the temporary file always goes.
    @Test func theInstallCommandValidatesBeforeInstalling() throws {
        let command = try #require(SleepRule.installCommand(user: "me"))
        let visudo = try #require(command.range(of: "/usr/sbin/visudo -cf"))
        let install = try #require(command.range(of: "/usr/bin/install -m 0440 -o root -g wheel"))
        #expect(visudo.lowerBound < install.lowerBound)
        #expect(command.contains("/etc/sudoers.d/aiterm"))
        #expect(command.contains("/bin/rm -f \"$t\""))
        #expect(SleepRule.removeCommand == "/bin/rm -f /etc/sudoers.d/aiterm")
    }

    @Test func theAppleScriptEscapesQuotesAndBackslashes() {
        #expect(SleepRule.appleScript(running: #"printf "%s\n" x"#)
                == #"do shell script "printf \"%s\\n\" x" with administrator privileges"#)
    }
}
