from datetime import datetime
from pathlib import Path
import re
import shutil
import subprocess
import time
import tkinter as tk
from tkinter import messagebox

# === НАСТРОЙКИ ===
SOURCE_DIR = Path(
    r"d:\SQLArchiv"
)  # Папка, куда складываются .sql файлы
REPO_DIR = Path(
    r"d:\SQLArchiv"
)  # Папка локального Git-репозитория
BRANCH = "main"  # Целевая ветка
CHECK_INTERVAL_SEC = 3  # Интервал проверки папки (в секундах)

ARCHIVE_DIR = SOURCE_DIR / "archiv"
ERROR_DIR = SOURCE_DIR / "error"

PROC_HEADER_RE = re.compile(
    r"^(\s*)(?:CREATE\s+OR\s+ALTER|ALTER|CREATE)\s+PROC(?:EDURE)?\b",
    re.IGNORECASE | re.MULTILINE,
)


def read_sql_with_auto_encoding(file_path: Path) -> str:
  """Читает файл с учётом кодировок SSMS (UTF-16, UTF-8-BOM, CP1251)."""
  raw = file_path.read_bytes()
  if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
    return raw.decode("utf-16")
  try:
    return raw.decode("utf-8-sig")
  except UnicodeDecodeError:
    return raw.decode("cp1251")


def normalize_procedure_sql(sql_text: str) -> str:
  """Заменяет ALTER / CREATE OR ALTER PROC(EDURE) на CREATE PROCEDURE."""
  return PROC_HEADER_RE.sub(r"\1CREATE PROCEDURE", sql_text)


def run_git(args: list[str], cwd: Path) -> str:
  # CREATE_NO_WINDOW (0x08000000) не даёт мигать чёрному окну консоли git.exe в Windows
  creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
  result = subprocess.run(
      ["git", "-c", "core.quotepath=false", *args],
      cwd=cwd,
      capture_output=True,
      text=True,
      encoding="utf-8",
      check=True,
      creationflags=creationflags,
  )
  return result.stdout.strip()


def get_pending_sql_files() -> list[Path]:
  """Находит все новые .sql файлы, исключая папки archiv, error и .git."""
  if not SOURCE_DIR.exists():
    return []

  excluded_roots = {ARCHIVE_DIR.resolve(), ERROR_DIR.resolve()}
  found_files = []

  for path in SOURCE_DIR.glob("*.sql"):
    if not path.is_file():
      continue
    if ".git" in path.parts:
      continue
    resolved = path.resolve()
    if any(
        ex == resolved or ex in resolved.parents for ex in excluded_roots
    ):
      continue
    found_files.append(path)

  return sorted(found_files)


def move_files(files: list[Path], target_root: Path) -> None:
  """Переносит файлы в archiv или error с сохранением относительной структуры папок."""
  for src in files:
    if not src.exists():
      continue
    rel_path = src.relative_to(SOURCE_DIR)
    dst = target_root / rel_path
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.unlink(
        missing_ok=True
    )  # Перезаписываем, если файл с таким именем уже был в архиве
    shutil.move(str(src), str(dst))


def show_modal_prompt(files: list[Path]) -> bool:
  """Показывает модальное окно поверх всех окон со списком файлов. Возвращает True при согласии."""
  user_choice = False

  root = tk.Tk()
  root.withdraw()
  root.attributes("-topmost", True)

  dialog = tk.Toplevel(root)
  dialog.title("SQL Git Sync — Новые файлы")
  dialog.attributes("-topmost", True)
  dialog.resizable(False, False)

  # Центрируем окно на экране
  width, height = 540, 340
  x = (dialog.winfo_screenwidth() // 2) - (width // 2)
  y = (dialog.winfo_screenheight() // 2) - (height // 2)
  dialog.geometry(f"{width}x{height}+{x}+{y}")

  header = tk.Label(
      dialog,
      text=f"Обнаружены новые SQL-файлы ({len(files)} шт.).\nОтправить изменения в Git?",
      font=("Segoe UI", 10, "bold"),
      justify="left",
      padx=15,
      pady=10,
  )
  header.pack(fill="x")

  # Область со списком файлов и прокруткой
  frame = tk.Frame(dialog, padx=15)
  frame.pack(fill="both", expand=True)

  scrollbar = tk.Scrollbar(frame)
  scrollbar.pack(side="right", fill="y")

  text_box = tk.Text(
      frame,
      height=10,
      font=("Consolas", 9),
      yscrollcommand=scrollbar.set,
      bg="#f8f9fa",
      relief="solid",
      borderwidth=1,
  )
  for f in files:
    text_box.insert("end", f" • {f.relative_to(SOURCE_DIR)}\n")
  text_box.config(state="disabled")
  text_box.pack(side="left", fill="both", expand=True)
  scrollbar.config(command=text_box.yview)

  # Кнопки выбора
  btn_frame = tk.Frame(dialog, pady=12, padx=15)
  btn_frame.pack(fill="x")

  def on_approve():
    nonlocal user_choice
    user_choice = True
    root.destroy()

  def on_reject():
    nonlocal user_choice
    user_choice = False
    root.destroy()

  btn_yes = tk.Button(
      btn_frame,
      text="Да, в Git (перенести в archiv)",
      command=on_approve,
      bg="#198754",
      fg="white",
      font=("Segoe UI", 9, "bold"),
      padx=12,
      pady=5,
  )
  btn_yes.pack(side="left", expand=True, fill="x", padx=(0, 6))

  btn_no = tk.Button(
      btn_frame,
      text="Нет (перенести в error)",
      command=on_reject,
      bg="#dc3545",
      fg="white",
      font=("Segoe UI", 9, "bold"),
      padx=12,
      pady=5,
  )
  btn_no.pack(side="right", expand=True, fill="x", padx=(6, 0))

  dialog.protocol("WM_DELETE_WINDOW", on_reject)
  dialog.grab_set()
  dialog.focus_force()
  root.mainloop()

  return user_choice


def show_error_popup(title: str, message: str) -> None:
  """Показывает окно ошибки в фоновом режиме (так как консоли нет)."""
  root = tk.Tk()
  root.withdraw()
  root.attributes("-topmost", True)
  messagebox.showerror(title, message, parent=root)
  root.destroy()


def process_batch(files: list[Path]) -> None:
  approved = show_modal_prompt(files)

  if not approved:
    move_files(files, ERROR_DIR)
    return

  # Копируем и нормализуем файлы в папку репозитория
  for src_file in files:
    if not src_file.exists():
      continue
    rel_path = src_file.relative_to(SOURCE_DIR)
    dst_file = REPO_DIR / rel_path
    dst_file.parent.mkdir(parents=True, exist_ok=True)

    original_text = read_sql_with_auto_encoding(src_file)
    normalized_text = normalize_procedure_sql(original_text)
    dst_file.write_bytes(normalized_text.encode("utf-8"))

  # Фиксируем изменения в Git
    # Вместо run_git(["add", "."], REPO_DIR) добавляйте только сами файлы:
    for src_file in files:
        rel_path = src_file.relative_to(SOURCE_DIR)
        run_git(["add", str(rel_path)], REPO_DIR)
  status = run_git(["status", "--porcelain"], REPO_DIR)

  if status:
    names = [f.name for f in files]
    preview = ", ".join(names[:5]) + (
        f" и ещё {len(names) - 5}" if len(names) > 5 else ""
    )
    commit_msg = (
        f"Update SQL procedures ({datetime.now():%Y-%m-%d %H:%M:%S}): {preview}"
    )

    run_git(["commit", "-m", commit_msg], REPO_DIR)
    run_git(["push", "origin", BRANCH], REPO_DIR)

  # Переносим исходники в archiv только после успешного push
  move_files(files, ARCHIVE_DIR)


def watch_loop() -> None:
  SOURCE_DIR.mkdir(parents=True, exist_ok=True)
  ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
  ERROR_DIR.mkdir(parents=True, exist_ok=True)

  while True:
    files = get_pending_sql_files()
    if files:
      # Пауза 1 сек, чтобы SSMS или проводник успели дописать файлы на диск
      time.sleep(1)
      files = get_pending_sql_files()
      if files:
        try:
          process_batch(files)
        except subprocess.CalledProcessError as e:
          show_error_popup(
              "Ошибка Git",
              f"Не удалось выполнить push. Файлы оставлены в папке.\n\n{e.stderr}",
          )
          time.sleep(10)
        except Exception as e:
          show_error_popup("Ошибка синхронизации", str(e))
          time.sleep(10)

    time.sleep(CHECK_INTERVAL_SEC)


if __name__ == "__main__":
  watch_loop()