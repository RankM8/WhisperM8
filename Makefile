.PHONY: run build kill clean help

help:
	@echo "WhisperM8 Development Commands:"
	@echo "  make run    - Build and run (kills old instances)"
	@echo "  make build  - Build only"
	@echo "  make kill   - Kill all running instances"
	@echo "  make clean  - Clean build artifacts"

run:
	@./scripts/run.sh

build:
	@./scripts/build.sh

kill:
	@./scripts/kill.sh

clean:
	@echo "🧹 Cleaning..."
	@xcodebuild clean -scheme WhisperM8 -quiet 2>/dev/null || true
	@echo "✅ Cleaned"
