# Signals by section

**Do not open this workspace with an older AiTerm once you have made a project signal.** An older
build that saves the workspace forgets a signal's kind: a project signal with a Done query becomes
an Operator signal there, and one with **You decide** stops running. Everything else, including
the marks on tasks a signal started, is kept.

Nothing needs doing to upgrade. Your signals are Operator signals, as before, and your tasks, the
Archive and saved conversations are all there. Dividers you had made between signals are no longer
drawn; they stay in the saved workspace.

## What changes

### Two kinds of signal

- **Project signals** are new. One picks an item up (a merge request where you are reviewer, a
  ticket, a schedule's time) and starts an ordinary task or review in its project with your prompt
  and one agent, then leaves it to you. There is no Operator chat: its agent asks you directly, in
  its own window, and no branch guard applies, as for a task you make.
- Its window opens behind, once you pause typing. When the turn your prompt started ends, one
  notification says it is ready for you, or that it asks you something; clicking it opens the task.
- When the item matches again (a review asked again), the prompt is typed into the same
  conversation once the agent is idle with nothing unsent, restoring an archived task first.
- Its Done is **A query matches** or **You decide**, and **Then** keeps or archives the task.
- **Operator signals** work as before. Pausing the Operator pauses only them.
- **File › New Signal…** (⌘S) makes the open section's kind: a project signal with Projects open,
  an Operator signal with Operator open. Each heading's **+** does the same.
- New Signal's steps are Signal, Starts when, Agents, Prompt, Done when.

### Sidebar

- Both sections group tasks by project. Under **Operator**, the projects with a task it runs sit
  under their dividers, each folding on its own. Signal headings are gone, and so is Add Divider…
  under the Operator.
- Each section heading has a signals icon with a count, left of its **+**. It opens that section's
  signals sheet: each signal with its Starts and Done lines, what needs you, and its menu (Edit,
  Switch Off/On, Move Up/Down for priority, Remove). Project signals take an item before Operator
  signals.
- A source that can't be read, or a skipped item, turns the icon amber. After three failed reads in
  a row a banner names the signal and when AiTerm tries again, with **Open Signals** and
  **Settings…**; it goes by itself at the next good read.
- A task a signal started wears a small disc on its avatar. Rest the pointer on it to see which
  signals ran the task, and when, and what is going on now.
- The Operator's row reads **Running 3 tasks**. A line runs down the status column from its mark
  through each task it runs: dotted and moving while the Operator works on a task or the task wakes
  it, amber while a question waits for you. A folded project shows a dot on the line.
