import SwiftUI

/// The Codex group at the bottom of the window's Running card: no box of its own, on the Running rows' two lines.
/// The label "Codex N" (the section labels' 600 11 in Codex's colour, count quieter) sits on the title line; each row
/// puts a 7 pt dot (the running colour, the delegate teal while it waits on its subagents; idle is a hollow 1.5 pt ring)
/// in the glyph column, then `repo · title` 12 and "Running tool · 93m" / "Idle · 18m" 11.5 grey, 22 high. A row
/// click jumps; a jump that missed leaves its note below. Owner: stream C.
struct CodexGroupView: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(\.needsYouColour) private var needsYou
    let rows: [SessionRow]
    var metrics: DetailedRowMetrics = .window
    /// false: the card's own title is the group's label (nothing runs), so the group does not repeat it.
    var titled = true
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titled {
                HStack(spacing: 7) {
                    Text("Codex").foregroundStyle(theme.island.toneText(IslandTheme.agentCodex))
                    Text("\(rows.count)").monospacedDigit().foregroundStyle(WindowTheme.sectionCount)
                }
                .font(WindowTheme.TypeScale.sectionHeader)
                .tracking(0.11)
                .lineBox(22)
                .padding(.leading, metrics.leading)
                .accessibilityElement(children: .combine)
            }
            ForEach(rows) { row in groupRow(row).id(row.id) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupRow(_ row: SessionRow) -> some View {
        let idle = row.bucket != .running
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if idle {
                        Circle().strokeBorder(theme.island.idleMark, lineWidth: 1.5)
                    } else {
                        Circle().fill(GlyphPalette.colour(agent: row.agent, state: row.glyphState == .delegating ? .delegating : .running,
                                                          mode: env.settings.glyphColour, needsYou: needsYou))
                    }
                }
                .frame(width: 7, height: 7)
                .frame(width: metrics.glyphBox)
                .frame(width: metrics.leading, alignment: .leading)
                HStack(spacing: 6) {
                    // The title is cut, never the short status (a first prompt runs up to 200 characters, P209).
                    RowTitleLine.text(row, size: 12, palette: theme.island)
                        .lineLimit(1).truncationMode(.tail)
                        .help(SessionRowText.titleHelp(row))
                    Text(SessionListLayout.groupStatus(row, now: env.sessions.now)).font(Fonts.sys(11.5)).foregroundStyle(theme.island.ink2)
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .lineBox(22)
            JumpNoteLine(sessionID: row.id).padding(.leading, metrics.leading)
        }
        .background {
            // The keys' row (P321): the rows' lift, a little wider than the row's own lines.
            if env.windowSelection == row.id {
                let shape = RoundedRectangle(cornerRadius: 8)
                shape.fill(theme.island.rowHover).overlay(shape.strokeBorder(theme.island.selectionRing, lineWidth: SelectionMark.ringWidth))
                    .padding(.horizontal, -6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { env.sessions.jump(row.id) }
        .sessionMenu(row)
        .help(SessionListLayout.rowHelp(row))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
