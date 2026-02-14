.PHONY: run run-env test fmt clippy lint

run:
	cargo run

run-env:
	@set -a; [ -f ./.env ] && . ./.env; set +a; cargo run

test:
	cargo test

fmt:
	cargo fmt

clippy:
	cargo clippy -- -D warnings

lint:
	cargo fmt --check
	cargo clippy -- -D warnings
