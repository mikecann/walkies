import Foundation
import Testing
@testable import Walkies

@MainActor
struct AvatarTests {
    @Test(arguments: [
        ("Mike Cann", "MC"),
        ("mike", "M"),
        ("  Mary Jane van Dyke ", "MD"),
        ("Test walker 4F2A", "T4"),
        ("mike.cann@gmail.com", "MC"),
        ("Zoë", "Z"),
        ("", "?"),
        ("   ", "?"),
        ("🐕 ✨", "?"),
    ])
    func initials(name: String, expected: String) {
        #expect(Head.initials(name) == expected)
    }

    @Test func noNameIsAQuestionMark() {
        #expect(Head.initials(nil) == "?")
    }

    @Test func pileShowsUpToThreeWithoutABubble() {
        #expect(HeadPile.visible(["you"]) == (["you"], 0))
        #expect(HeadPile.visible(["a", "b", "you"]) == (["a", "b", "you"], 0))
    }

    @Test func pileKeepsYourHeadAndCountsTheRest() {
        let pile = HeadPile.visible(["a", "b", "c", "d", "e", "you"])
        #expect(pile.shown == ["a", "b", "you"])
        #expect(pile.extra == 3)
    }

    @Test func emptyPileIsEmpty() {
        #expect(HeadPile.visible([String]()) == ([], 0))
    }

    @Test func teamHeadsPutYouLastWithYourOwnPhoto() {
        let members = [
            TeamMember(userId: "me", name: "Mike", colour: "teal", joinedAt: 1, isYou: true, picture: "https://example.com/old.jpg"),
            TeamMember(userId: "dad", name: "Dad", colour: "blue", joinedAt: 2, isYou: false, picture: "https://example.com/dad.jpg"),
        ]
        let team = Team(id: "team", name: "Mike & Dad", createdBy: "me", inviteCode: "ABCD2345", members: members)
        let you = Head(id: "you", name: "Mike", picture: URL(string: "https://example.com/new.jpg"), colour: .walkiesOrange)
        let heads = Head.team(team, you: you)
        #expect(heads.map(\.id) == ["dad", "me"])
        #expect(heads[0].picture?.absoluteString == "https://example.com/dad.jpg")
        #expect(heads[1].picture?.absoluteString == "https://example.com/new.jpg")
    }

    @Test func memberWithoutPictureStillDecodes() throws {
        let json = #"{"userId":"u","name":"Dad","colour":"blue","joinedAt":1,"isYou":false}"#
        let member = try JSONDecoder().decode(TeamMember.self, from: Data(json.utf8))
        #expect(member.picture == nil)
        let withPicture = try JSONDecoder().decode(TeamMember.self, from: Data(json.replacingOccurrences(of: "}", with: #","picture":"https://x.test/p"}"#).utf8))
        #expect(withPicture.picture == "https://x.test/p")
    }
}
