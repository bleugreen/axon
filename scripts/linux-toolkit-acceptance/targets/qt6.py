#!/usr/bin/env python3
"""Qt 6 target.

Qt passes synthetic events through without filtering them, which is framework neutrality rather than
a guarantee. Whether an application above it reacts is the thing worth measuring.
"""

import os
import sys

try:
    from PyQt6.QtCore import QEvent, QObject, QPoint, Qt, QTimer, QT_VERSION_STR
    from PyQt6.QtWidgets import QApplication, QLineEdit, QPushButton, QVBoxLayout, QWidget

    BINDING = "PyQt6"
except ImportError:  # whichever binding this machine has
    from PySide6 import __version__ as QT_VERSION_STR
    from PySide6.QtCore import QEvent, QObject, QPoint, Qt, QTimer
    from PySide6.QtWidgets import QApplication, QLineEdit, QPushButton, QVBoxLayout, QWidget

    BINDING = "PySide6"

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from report import report  # noqa: E402


class RawWatch(QObject):
    """Reports raw arrival at the toolkit, separately from the effect.

    "Qt never saw the event" and "Qt saw it and declined to act" are different answers about a
    delivery mechanism, and only the effect is visible from outside the process.
    """

    WATCHED = {QEvent.Type.MouseButtonPress: "button-press", QEvent.Type.KeyPress: "key-press"}

    def eventFilter(self, receiver, event) -> bool:
        what = self.WATCHED.get(event.type())
        if what:
            report({"kind": "raw", "event": what, "spontaneous": bool(event.spontaneous())})
        return False


class Target(QWidget):
    def __init__(self) -> None:
        super().__init__()
        self.clicks = 0
        self.setWindowTitle("Axon harness Qt6")
        self.resize(480, 320)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(24)
        self.entry = QLineEdit(self)
        self.button = QPushButton("Target Button", self)
        self.button.setMinimumSize(200, 80)
        # The button must not take widget focus: a click landing on it would otherwise move focus
        # off the text field and turn the keyboard phases into a measurement of the button.
        self.button.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.button.clicked.connect(self.on_click)
        self.entry.textChanged.connect(self.on_text)
        layout.addWidget(self.entry)
        layout.addWidget(self.button)
        layout.addStretch(1)
        self.show()
        self.entry.setFocus()
        QTimer.singleShot(600, self.announce)

    def rectangle(self, widget) -> list:
        origin = widget.mapTo(self, QPoint(0, 0))
        return [origin.x(), origin.y(), widget.width(), widget.height()]

    def announce(self) -> None:
        report(
            {
                "kind": "ready",
                "pid": os.getpid(),
                "xid": int(self.winId()),
                "signature": f"Qt {QT_VERSION_STR} via {BINDING}",
                "widgets": {
                    "button": self.rectangle(self.button),
                    "entry": self.rectangle(self.entry),
                },
            }
        )

    def on_click(self) -> None:
        self.clicks += 1
        report({"kind": "click", "widget": "button", "count": self.clicks})

    def on_text(self, value: str) -> None:
        report({"kind": "text", "widget": "entry", "value": value})


application = QApplication(sys.argv)
watch = RawWatch()
application.installEventFilter(watch)
target = Target()
sys.exit(application.exec())
