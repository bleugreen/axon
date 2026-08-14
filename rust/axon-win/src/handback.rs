#![cfg_attr(not(windows), allow(dead_code))]

use std::{fmt, str::FromStr};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HandBackStrategy {
    NoDispatch,
    Baseline,
    HeldAttachment,
    AllowForeground,
    AltInput,
    SwitchWindow,
    AttachedActivation,
    ForegroundLockTimeout,
}

impl HandBackStrategy {
    pub(crate) const ALL: [Self; 8] = [
        Self::NoDispatch,
        Self::Baseline,
        Self::HeldAttachment,
        Self::AllowForeground,
        Self::AltInput,
        Self::SwitchWindow,
        Self::AttachedActivation,
        Self::ForegroundLockTimeout,
    ];

    pub(crate) fn letter(self) -> &'static str {
        match self {
            Self::NoDispatch => "A",
            Self::Baseline => "B",
            Self::HeldAttachment => "C",
            Self::AllowForeground => "D",
            Self::AltInput => "E",
            Self::SwitchWindow => "F",
            Self::AttachedActivation => "G",
            Self::ForegroundLockTimeout => "H",
        }
    }
}

impl fmt::Display for HandBackStrategy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.letter())
    }
}

impl FromStr for HandBackStrategy {
    type Err = String;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|strategy| strategy.letter().eq_ignore_ascii_case(value))
            .ok_or_else(|| {
                format!("unknown hand-back strategy {value:?}; expected A, B, C, D, E, F, G, or H")
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strategy_sweep_is_ordered_and_complete() {
        assert_eq!(
            HandBackStrategy::ALL.map(|value| value.letter()).join(""),
            "ABCDEFGH"
        );
    }

    #[test]
    fn strategy_selection_is_case_insensitive_and_refuses_unknown_names() {
        assert_eq!("h".parse(), Ok(HandBackStrategy::ForegroundLockTimeout));
        assert!(
            "timeout"
                .parse::<HandBackStrategy>()
                .unwrap_err()
                .contains("expected A")
        );
    }
}
