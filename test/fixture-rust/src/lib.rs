//! rust-checks.yml's self-test fixture: fmt-clean, clippy-clean, one test.

/// Adds two numbers.
pub fn add(a: u32, b: u32) -> u32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 3), 5);
    }
}
