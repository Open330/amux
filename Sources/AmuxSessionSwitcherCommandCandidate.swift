import CmuxCommandPalette

/// One open or available tmux target before unified attention-first ranking.
struct AmuxSessionSwitcherCommandCandidate {
    let command: CommandPaletteCommand
    let item: AmuxSessionSwitcherItem
    let isOpen: Bool
    let isCurrent: Bool
}
