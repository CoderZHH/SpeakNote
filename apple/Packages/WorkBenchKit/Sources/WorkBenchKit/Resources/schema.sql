CREATE TABLE IF NOT EXISTS accounts (
      id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL CHECK(platform IN ('douyin','bilibili','xiaohongshu','x','tiktok','instagram','youtube')),
      profile TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT 'yellow', created_at TEXT NOT NULL
    , tags TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS focus_intervals (
      id TEXT PRIMARY KEY, focus_id TEXT NOT NULL REFERENCES focus_sessions(id) ON DELETE CASCADE,
      started_at TEXT NOT NULL, ended_at TEXT
    );
CREATE TABLE IF NOT EXISTS focus_sessions (
      id TEXT PRIMARY KEY, task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
      started_at TEXT NOT NULL, active_since TEXT, elapsed_seconds INTEGER NOT NULL DEFAULT 0,
      untracked_seconds INTEGER CHECK(untracked_seconds IS NULL OR (typeof(untracked_seconds)='integer' AND untracked_seconds>=0)),
      goal_seconds INTEGER NOT NULL DEFAULT 1500, status TEXT NOT NULL CHECK(status IN ('running','paused','ended')), ended_at TEXT
    );
CREATE TABLE IF NOT EXISTS spaces (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, symbol TEXT NOT NULL DEFAULT 'folder',
      color TEXT NOT NULL DEFAULT 'blue',
      allows_lessons INTEGER NOT NULL DEFAULT 0 CHECK(typeof(allows_lessons)='integer' AND allows_lessons IN (0,1)),
      legacy_entity TEXT CHECK(legacy_entity IS NULL OR legacy_entity IN ('projects','learning')),
      position INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done')),
      completed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
CREATE TABLE IF NOT EXISTS collections (
      id TEXT PRIMARY KEY, space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
      title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
      color TEXT NOT NULL DEFAULT 'blue',
      parent_id TEXT REFERENCES collections(id) ON DELETE CASCADE,
      position INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done')),
      completed_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    );
CREATE TABLE IF NOT EXISTS learning (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT 'mint', created_at TEXT NOT NULL
    , parent_id TEXT REFERENCES learning(id) ON DELETE CASCADE, position INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done')), completed_at TEXT);
CREATE TABLE IF NOT EXISTS lessons (
      id TEXT PRIMARY KEY, learning_id TEXT REFERENCES learning(id) ON DELETE CASCADE,
      collection_id TEXT REFERENCES collections(id) ON DELETE CASCADE,
      title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
      task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL
    , parent_id TEXT REFERENCES lessons(id) ON DELETE CASCADE,
      CHECK((learning_id IS NOT NULL)+(collection_id IS NOT NULL)=1));
CREATE TABLE IF NOT EXISTS metrics (
      id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      video_id TEXT NOT NULL, title TEXT NOT NULL, url TEXT NOT NULL DEFAULT '', published_at TEXT NOT NULL DEFAULT '',
      plays INTEGER, likes INTEGER, comments INTEGER, shares INTEGER, followers INTEGER, captured_at TEXT NOT NULL,
      source TEXT NOT NULL DEFAULT 'import', UNIQUE(account_id, video_id, captured_at)
    );
CREATE TABLE IF NOT EXISTS notes (
      id TEXT PRIMARY KEY, content TEXT NOT NULL, remark TEXT NOT NULL DEFAULT '', color TEXT NOT NULL DEFAULT 'yellow',
      status TEXT NOT NULL DEFAULT 'inbox' CHECK(status IN ('inbox','processed','archived')), created_at TEXT NOT NULL
    , project_id TEXT REFERENCES projects(id) ON DELETE SET NULL, learning_id TEXT REFERENCES learning(id) ON DELETE SET NULL, course_id TEXT REFERENCES courses(id) ON DELETE SET NULL, collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL);
CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
      color TEXT NOT NULL DEFAULT 'yellow', status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done')), created_at TEXT NOT NULL
    , repo_path TEXT, completed_at TEXT, position INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS reflections (
      id TEXT PRIMARY KEY, day TEXT NOT NULL, content TEXT NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    , tags TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, notes TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'todo' CHECK(status IN ('todo','done','abandoned')),
      planned_date TEXT, due_date TEXT, priority TEXT NOT NULL DEFAULT 'normal' CHECK(priority IN ('normal','high')),
      project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
      learning_id TEXT REFERENCES learning(id) ON DELETE SET NULL,
      course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
      collection_id TEXT REFERENCES collections(id) ON DELETE SET NULL,
      source_note_id TEXT REFERENCES notes(id) ON DELETE SET NULL,
      estimate INTEGER NOT NULL DEFAULT 25, important INTEGER NOT NULL DEFAULT 0, resume_hint TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, completed_at TEXT
    , start_time TEXT, end_time TEXT, abandoned_at TEXT, reminder_enabled INTEGER NOT NULL DEFAULT 0 CHECK(typeof(reminder_enabled)='integer' AND reminder_enabled IN (0,1)), reminder_at TEXT, importance INTEGER NOT NULL DEFAULT 1 CHECK(typeof(importance)='integer' AND importance BETWEEN 1 AND 5));
CREATE INDEX IF NOT EXISTS metric_history ON metrics(account_id, captured_at);
CREATE UNIQUE INDEX IF NOT EXISTS one_open_focus_interval ON focus_intervals(focus_id) WHERE ended_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS one_running_focus ON focus_sessions((1)) WHERE status='running';
CREATE INDEX IF NOT EXISTS reflections_day ON reflections(day, created_at);
CREATE INDEX IF NOT EXISTS tasks_planned ON tasks(status, planned_date);
CREATE TABLE IF NOT EXISTS attachments (
 id TEXT PRIMARY KEY, file_key TEXT NOT NULL, name TEXT NOT NULL, mime TEXT NOT NULL,
 size INTEGER NOT NULL CHECK(size>0 AND size<=104857600), sha256 TEXT NOT NULL, created_at TEXT NOT NULL,
 task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
 note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
 project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
 learning_id TEXT REFERENCES learning(id) ON DELETE CASCADE,
 course_id TEXT REFERENCES courses(id) ON DELETE CASCADE,
 collection_id TEXT REFERENCES collections(id) ON DELETE CASCADE,
 CHECK((task_id IS NOT NULL)+(note_id IS NOT NULL)+(project_id IS NOT NULL)+(learning_id IS NOT NULL)+(course_id IS NOT NULL)+(collection_id IS NOT NULL)=1)
);

CREATE INDEX IF NOT EXISTS focus_interval_session ON focus_intervals(focus_id,started_at);

CREATE TABLE IF NOT EXISTS semesters (
 id TEXT PRIMARY KEY, title TEXT NOT NULL, first_monday TEXT NOT NULL, weeks INTEGER NOT NULL CHECK(weeks BETWEEN 1 AND 40),
 periods TEXT NOT NULL, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS courses (
 id TEXT PRIMARY KEY, semester_id TEXT NOT NULL REFERENCES semesters(id) ON DELETE CASCADE,
 title TEXT NOT NULL, teacher TEXT NOT NULL DEFAULT '', code TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '',
 color TEXT NOT NULL DEFAULT '#648ba8', status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active','paused','done')),
 completed_at TEXT, created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS course_meetings (
 id TEXT PRIMARY KEY, course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
 weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7), weeks TEXT NOT NULL,
 period_start INTEGER NOT NULL CHECK(period_start BETWEEN 1 AND 24), period_end INTEGER NOT NULL CHECK(period_end>=period_start AND period_end<=24),
 room TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS meetings_course ON course_meetings(course_id);
