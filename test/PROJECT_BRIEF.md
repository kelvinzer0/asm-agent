# Project Brief: Build a Complete Task Management System

## Overview
Build a fully functional Task Management System (TMS) from scratch using Python.
This is a comprehensive project that tests multi-step planning, error recovery,
and complex implementation.

## Requirements

### Phase 1: Core Data Model
- Create `task.py` with a Task class containing:
  - id (auto-increment)
  - title (string)
  - description (string)
  - priority (low/medium/high/critical)
  - status (todo/in_progress/done/archived)
  - created_at (ISO timestamp)
  - updated_at (ISO timestamp)
  - tags (list of strings)
  - due_date (optional ISO date)

### Phase 2: Storage Engine
- Create `storage.py` with JSON file-based storage:
  - save(task) - persist task to tasks.json
  - load(task_id) - retrieve single task
  - load_all() - retrieve all tasks
  - delete(task_id) - remove task
  - search(query) - search by title/description
  - filter_by_status(status) - filter tasks
  - filter_by_priority(priority) - filter by priority
  - get_statistics() - return counts by status/priority

### Phase 3: CLI Interface
- Create `cli.py` with command-line interface:
  - `python cli.py add "Title" --priority high --tag work`
  - `python cli.py list [--status todo] [--priority high]`
  - `python cli.py show <id>`
  - `python cli.py update <id> --status done`
  - `python cli.py delete <id>`
  - `python cli.py search "keyword"`
  - `python cli.py stats`
  - `python cli.py export --format csv`

### Phase 4: Advanced Features
- Create `scheduler.py` with:
  - Overdue task detection
  - Priority-based sorting
  - Due date reminders
  - Weekly report generation

### Phase 5: Testing & Documentation
- Create `test_tms.py` with unit tests for all modules
- Create `README.md` with usage examples

## Success Criteria
1. All files created and functional
2. Can add, list, update, delete tasks via CLI
3. Search and filter work correctly
4. Statistics are accurate
5. All tests pass
6. No errors on any command

## File Structure Expected
```
test/
├── task.py
├── storage.py
├── cli.py
├── scheduler.py
├── test_tms.py
├── README.md
└── tasks.json (created at runtime)
```

## Difficulty Level: EXTREME
This project requires:
- 6+ Python files
- 1000+ lines of code
- Complex data structures
- File I/O operations
- CLI argument parsing
- JSON serialization
- Date/time handling
- Search algorithms
- Unit testing
- Error handling throughout
