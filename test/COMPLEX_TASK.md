# Complex Task: Fix and Complete the Task Management System

## Context
The test/ folder contains a Task Management System (TMS) that is INCOMPLETE.
Read PROJECT_BRIEF.md for full requirements.

## Current State
- task.py: Has minimal Task class (missing methods)
- storage.py: Empty stub (25 bytes)
- cli.py: Empty stub (25 bytes)
- scheduler.py: Empty stub (25 bytes)
- test_tms.py: Empty stub (25 bytes)

## Your Mission (Multi-Step)

### Step 1: Analyze
- Read PROJECT_BRIEF.md
- Read all existing .py files
- Identify what's missing

### Step 2: Implement Core (task.py + storage.py)
- Complete Task class with all required fields and methods
- Implement storage.py with JSON file-based CRUD
- Test: `python3 task.py` and `python3 storage.py` should not error

### Step 3: Implement CLI (cli.py)
- Build full CLI with argparse
- Support: add, list, show, update, delete, search, stats, export
- Test: `python3 cli.py add "Test Task" --priority high`
- Test: `python3 cli.py list`
- Test: `python3 cli.py stats`

### Step 4: Implement Scheduler (scheduler.py)
- Overdue detection, priority sorting, weekly report
- Test: `python3 scheduler.py report`

### Step 5: Write Tests (test_tms.py)
- Unit tests for Task, Storage, CLI
- Run: `python3 -m pytest test_tms.py -v`
- All tests must pass

### Step 6: Final Verification
- Run full CLI workflow:
  ```
  python3 cli.py add "Buy groceries" --priority high --tag personal
  python3 cli.py add "Write report" --priority medium --tag work --due 2026-06-30
  python3 cli.py list
  python3 cli.py list --status todo
  python3 cli.py list --priority high
  python3 cli.py search "report"
  python3 cli.py stats
  python3 cli.py update 1 --status done
  python3 cli.py show 1
  python3 cli.py export --format csv
  python3 cli.py delete 2
  ```
- All commands must succeed without errors
- Run tests again to confirm

## Success Criteria
1. All 5 .py files fully implemented
2. CLI handles all 8 commands
3. Storage CRUD works correctly
4. All pytest tests pass
5. No errors on any command
6. CSV export produces valid output

## Difficulty: EXTREME
This tests: planning, implementation, debugging, testing, multi-file coordination.
