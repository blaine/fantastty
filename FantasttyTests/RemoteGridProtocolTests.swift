import XCTest
@testable import Fantastty

final class RemoteGridProtocolTests: XCTestCase {
    func testPaneKeyframeRoundTripsThroughJSON() throws {
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: 4, rows: 2),
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text("h"), .text("i"), .blank, .blank
                ]),
                RemoteGridRow(index: 1, rowVersion: 12, cells: [
                    .text("你", width: 2), .continuation, .text("!"), .blank
                ])
            ],
            cursor: RemoteCursorState(row: 1, column: 2, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )

        let encoded = try JSONEncoder().encode(keyframe)
        let decoded = try JSONDecoder().decode(RemotePaneKeyframe.self, from: encoded)

        XCTAssertEqual(decoded, keyframe)
    }

    func testPaneDeltaRoundTripsThroughJSON() throws {
        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 12,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 13, update: .fullRow([
                    .text("o"), .text("k"), .blank, .blank
                ])),
                RemoteRowUpdate(rowIndex: 1, rowVersion: 14, update: .span(
                    baseRowVersion: 12,
                    startColumn: 2,
                    cells: [.text("!"), .blank],
                    clearToColumn: 4
                ))
            ],
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .bar)
        )

        let encoded = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(RemotePaneDelta.self, from: encoded)

        XCTAssertEqual(decoded, delta)
    }

    func testRemoteCursorStateRequiresCursorVersionInJSON() throws {
        let json = """
        {
          "row": 1,
          "column": 2,
          "visible": true,
          "shape": "block"
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(RemoteCursorState.self, from: Data(json.utf8)))

        let cursor = RemoteCursorState(
            row: 1,
            column: 2,
            visible: true,
            shape: .block,
            cursorVersion: 9
        )
        let decoded = try JSONDecoder().decode(
            RemoteCursorState.self,
            from: JSONEncoder().encode(cursor)
        )

        XCTAssertEqual(decoded, cursor)
    }

    func testRemoteCellStylePreservesUnderlineColorInJSON() throws {
        let json = """
        {
          "foreground": { "indexed": { "_0": 196 } },
          "background": { "default": {} },
          "underlineColor": { "rgb": { "red": 12, "green": 34, "blue": 56 } },
          "bold": false,
          "faint": false,
          "italic": true,
          "underline": "single",
          "blink": false,
          "inverse": false,
          "invisible": false,
          "strikethrough": false
        }
        """

        let decoded = try JSONDecoder().decode(RemoteCellStyle.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.underlineColor, .rgb(red: 12, green: 34, blue: 56))
        XCTAssertEqual(try roundTrip(decoded), decoded)
    }

    func testPaneDeltaDecodesRepresentativeJSONFixture() throws {
        let json = """
        {
          "workspaceID": "workspace-1",
          "paneID": 7,
          "paneGeneration": 3,
          "baseKeyframeID": 11,
          "deltaSequence": 12,
          "rowUpdates": [
            {
              "rowIndex": 0,
              "rowVersion": 13,
              "update": {
                "fullRow": {
                  "_0": [
                    {
                      "text": "A",
                      "width": 1,
                      "style": {
                        "foreground": { "indexed": { "_0": 196 } },
                        "background": { "rgb": { "red": 12, "green": 34, "blue": 56 } },
                        "underlineColor": { "rgb": { "red": 90, "green": 91, "blue": 92 } },
                        "bold": true,
                        "faint": true,
                        "italic": true,
                        "underline": "curly",
                        "blink": true,
                        "inverse": true,
                        "invisible": false,
                        "strikethrough": true
                      }
                    }
                  ]
                }
              }
            },
            {
              "rowIndex": 1,
              "rowVersion": 14,
              "update": {
                "span": {
                  "baseRowVersion": 12,
                  "startColumn": 2,
                  "cells": [
                    {
                      "text": "!",
                      "width": 1,
                      "style": {
                        "foreground": { "rgb": { "red": 200, "green": 210, "blue": 220 } },
                        "background": { "indexed": { "_0": 24 } },
                        "underlineColor": { "indexed": { "_0": 25 } },
                        "bold": false,
                        "faint": true,
                        "italic": false,
                        "underline": "dotted",
                        "blink": false,
                        "inverse": true,
                        "invisible": true,
                        "strikethrough": false
                      }
                    }
                  ],
                  "clearToColumn": 4
                }
              }
            }
          ],
          "cursor": {
            "row": 1,
            "column": 2,
            "visible": false,
            "shape": "underline",
            "cursorVersion": 7
          }
        }
        """
        let fullRowStyle = RemoteCellStyle(
            foreground: .indexed(196),
            background: .rgb(red: 12, green: 34, blue: 56),
            underlineColor: .rgb(red: 90, green: 91, blue: 92),
            bold: true,
            faint: true,
            italic: true,
            underline: .curly,
            blink: true,
            inverse: true,
            invisible: false,
            strikethrough: true
        )
        let spanStyle = RemoteCellStyle(
            foreground: .rgb(red: 200, green: 210, blue: 220),
            background: .indexed(24),
            underlineColor: .indexed(25),
            bold: false,
            faint: true,
            italic: false,
            underline: .dotted,
            blink: false,
            inverse: true,
            invisible: true,
            strikethrough: false
        )

        let decoded = try JSONDecoder().decode(RemotePaneDelta.self, from: Data(json.utf8))

        XCTAssertEqual(decoded, RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 12,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 13, update: .fullRow([
                    RemoteGridCell(text: "A", width: 1, style: fullRowStyle)
                ])),
                RemoteRowUpdate(rowIndex: 1, rowVersion: 14, update: .span(
                    baseRowVersion: 12,
                    startColumn: 2,
                    cells: [RemoteGridCell(text: "!", width: 1, style: spanStyle)],
                    clearToColumn: 4
                ))
            ],
            cursor: RemoteCursorState(
                row: 1,
                column: 2,
                visible: false,
                shape: .underline,
                cursorVersion: 7
            )
        ))
    }

    func testPaneDeltaDecodesCompactFullRowText() throws {
        let json = """
        {
          "workspaceID": "workspace-1",
          "paneID": 7,
          "paneGeneration": 3,
          "baseKeyframeID": 11,
          "deltaSequence": 12,
          "rowUpdates": [
            {
              "rowIndex": 0,
              "rowVersion": 13,
              "update": {
                "fullRowText": {
                  "_0": "ok "
                }
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(RemotePaneDelta.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.rowUpdates, [
            RemoteRowUpdate(rowIndex: 0, rowVersion: 13, update: .fullRow([
                .text("o"), .text("k"), .blank
            ]))
        ])
    }

    func testWorkspaceAndUnsupportedMessagesRoundTrip() throws {
        let snapshot = RemoteWorkspaceSnapshot(
            workspaceID: "workspace-1",
            layoutGeneration: 4,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24)
                )
            ]
        )

        let unsupported = RemoteUnsupportedPaneState(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            reason: .imageProtocol,
            fallback: .blankWithDiagnostic
        )

        XCTAssertEqual(try roundTrip(snapshot), snapshot)
        XCTAssertEqual(try roundTrip(unsupported), unsupported)
    }

    func testRemoteWorkspaceMessageRoundTripsAllKinds() throws {
        let snapshot = RemoteWorkspaceSnapshot(
            workspaceID: "workspace-1",
            layoutGeneration: 4,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24)
                )
            ]
        )
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: 2, rows: 1),
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [.text("o"), .text("k")])
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 12,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 11, update: .fullRow([.text("h"), .text("i")]))
            ],
            cursor: nil
        )
        let unsupported = RemoteUnsupportedPaneState(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            reason: .snapshotExtractionFailure,
            fallback: .keepLastGoodKeyframe
        )

        let messages: [RemoteWorkspaceMessage] = [
            .workspaceSnapshot(snapshot),
            .paneKeyframe(keyframe),
            .paneDelta(delta),
            .unsupportedPaneState(unsupported)
        ]

        for message in messages {
            XCTAssertEqual(try roundTrip(message), message)
        }
    }

    func testRemoteWorkspaceMessageDecodesRepresentativeJSONEnvelopeFixtures() throws {
        let fixtures: [(String, RemoteWorkspaceMessage)] = [
            ("""
            {
              "workspaceSnapshot": {
                "_0": {
                  "workspaceID": "workspace-1",
                  "layoutGeneration": 4,
                  "windows": [
                    { "windowID": 1, "title": "main", "index": 0, "isActive": true }
                  ],
                  "panes": [
                    {
                      "paneID": 7,
                      "windowID": 1,
                      "isActive": true,
                      "frame": { "x": 0, "y": 0, "columns": 80, "rows": 24 }
                    }
                  ]
                }
              }
            }
            """, .workspaceSnapshot(RemoteWorkspaceSnapshot(
                workspaceID: "workspace-1",
                layoutGeneration: 4,
                windows: [
                    RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
                ],
                panes: [
                    RemoteWorkspacePane(
                        paneID: 7,
                        windowID: 1,
                        isActive: true,
                        frame: RemotePaneFrame(x: 0, y: 0, columns: 80, rows: 24)
                    )
                ]
            ))),
            ("""
            {
              "paneKeyframe": {
                "_0": {
                  "workspaceID": "workspace-1",
                  "paneID": 7,
                  "paneGeneration": 3,
                  "keyframeID": 11,
                  "gridSize": { "columns": 2, "rows": 1 },
                  "rows": [
                    {
                      "index": 0,
                      "rowVersion": 10,
                      "cells": [
                        {
                          "text": "o",
                          "width": 1,
                          "style": {
                            "foreground": { "default": {} },
                            "background": { "default": {} },
                            "underlineColor": { "default": {} },
                            "bold": false,
                            "faint": false,
                            "italic": false,
                            "underline": "none",
                            "blink": false,
                            "inverse": false,
                            "invisible": false,
                            "strikethrough": false
                          }
                        },
                        {
                          "text": "k",
                          "width": 1,
                          "style": {
                            "foreground": { "default": {} },
                            "background": { "default": {} },
                            "underlineColor": { "default": {} },
                            "bold": false,
                            "faint": false,
                            "italic": false,
                            "underline": "none",
                            "blink": false,
                            "inverse": false,
                            "invisible": false,
                            "strikethrough": false
                          }
                        }
                      ]
                    }
                  ],
                  "cursor": {
                    "row": 0,
                    "column": 1,
                    "visible": true,
                    "shape": "block",
                    "cursorVersion": 1
                  },
                  "activeScreen": "primary",
                  "datagramsEnabledAfterKeyframe": true
                }
              }
            }
            """, .paneKeyframe(RemotePaneKeyframe(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                keyframeID: 11,
                gridSize: RemoteGridSize(columns: 2, rows: 1),
                rows: [
                    RemoteGridRow(index: 0, rowVersion: 10, cells: [.text("o"), .text("k")])
                ],
                cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
                activeScreen: .primary,
                datagramsEnabledAfterKeyframe: true
            ))),
            ("""
            {
              "paneKeyframe": {
                "_0": {
                  "workspaceID": "workspace-1",
                  "paneID": 7,
                  "paneGeneration": 3,
                  "keyframeID": 11,
                  "gridSize": { "columns": 2, "rows": 1 },
                  "rows": [
                    {
                      "index": 0,
                      "rowVersion": 10,
                      "text": "ok"
                    }
                  ],
                  "cursor": {
                    "row": 0,
                    "column": 1,
                    "visible": true,
                    "shape": "block",
                    "cursorVersion": 1
                  },
                  "activeScreen": "primary",
                  "datagramsEnabledAfterKeyframe": true
                }
              }
            }
            """, .paneKeyframe(RemotePaneKeyframe(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                keyframeID: 11,
                gridSize: RemoteGridSize(columns: 2, rows: 1),
                rows: [
                    RemoteGridRow(index: 0, rowVersion: 10, cells: [.text("o"), .text("k")])
                ],
                cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
                activeScreen: .primary,
                datagramsEnabledAfterKeyframe: true
            ))),
            ("""
            {
              "paneDelta": {
                "_0": {
                  "workspaceID": "workspace-1",
                  "paneID": 7,
                  "paneGeneration": 3,
                  "baseKeyframeID": 11,
                  "deltaSequence": 12,
                  "rowUpdates": [
                    {
                      "rowIndex": 0,
                      "rowVersion": 11,
                      "update": {
                        "fullRow": {
                          "_0": [
                            {
                              "text": "h",
                              "width": 1,
                              "style": {
                                "foreground": { "default": {} },
                                "background": { "default": {} },
                                "underlineColor": { "default": {} },
                                "bold": false,
                                "faint": false,
                                "italic": false,
                                "underline": "none",
                                "blink": false,
                                "inverse": false,
                                "invisible": false,
                                "strikethrough": false
                              }
                            },
                            {
                              "text": "i",
                              "width": 1,
                              "style": {
                                "foreground": { "default": {} },
                                "background": { "default": {} },
                                "underlineColor": { "default": {} },
                                "bold": false,
                                "faint": false,
                                "italic": false,
                                "underline": "none",
                                "blink": false,
                                "inverse": false,
                                "invisible": false,
                                "strikethrough": false
                              }
                            }
                          ]
                        }
                      }
                    }
                  ],
                  "cursor": null
                }
              }
            }
            """, .paneDelta(RemotePaneDelta(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                baseKeyframeID: 11,
                deltaSequence: 12,
                rowUpdates: [
                    RemoteRowUpdate(rowIndex: 0, rowVersion: 11, update: .fullRow([.text("h"), .text("i")]))
                ],
                cursor: nil
            ))),
            ("""
            {
              "unsupportedPaneState": {
                "_0": {
                  "workspaceID": "workspace-1",
                  "paneID": 7,
                  "paneGeneration": 3,
                  "reason": "snapshotExtractionFailure",
                  "fallback": "keepLastGoodKeyframe"
                }
              }
            }
            """, .unsupportedPaneState(RemoteUnsupportedPaneState(
                workspaceID: "workspace-1",
                paneID: 7,
                paneGeneration: 3,
                reason: .snapshotExtractionFailure,
                fallback: .keepLastGoodKeyframe
            )))
        ]

        for (json, expected) in fixtures {
            XCTAssertEqual(try JSONDecoder().decode(RemoteWorkspaceMessage.self, from: Data(json.utf8)), expected)
        }
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoded = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: encoded)
    }
}
