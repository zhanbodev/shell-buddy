"""Small VT screen for PTY assertions and cursor-position replies (test only)."""
import codecs
import unicodedata


class Screen:
    def __init__(self, columns=80, rows=24):
        self.columns, self.rows = columns, rows
        self.cells = [[" "] * columns for _ in range(rows)]
        self.x = self.y = 0
        self.saved = (0, 0)
        self.wrap = False
        self.sequence = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    @property
    def display(self):
        return ["".join(row).rstrip() for row in self.cells]

    def resize(self, columns, rows):
        self.cells = [(row[:columns] + [" "] * max(0, columns - len(row)))
                      for row in self.cells[:rows]]
        self.cells.extend([[" "] * columns for _ in range(rows - len(self.cells))])
        self.columns, self.rows = columns, rows
        self.x, self.y = min(self.x, columns - 1), min(self.y, rows - 1)
        self.wrap = False

    def newline(self):
        if self.y == self.rows - 1:
            self.cells.pop(0)
            self.cells.append([" "] * self.columns)
        else:
            self.y += 1

    def feed(self, data):
        responses = bytearray()
        for char in self.decoder.decode(data):
            if self.sequence:
                self.sequence += char
                if self.sequence.startswith("\x1b]"):
                    if char == "\x07" or self.sequence.endswith("\x1b\\"):
                        self.sequence = ""
                elif self.sequence.startswith("\x1b["):
                    if len(self.sequence) > 2 and "@" <= char <= "~":
                        responses.extend(self.csi(self.sequence[2:-1], char))
                        self.sequence = ""
                elif len(self.sequence) == 2:
                    if char == "7":
                        self.saved = self.x, self.y
                    elif char == "8":
                        self.x, self.y = self.saved
                    elif char == "D":
                        self.newline()
                    self.sequence = "" if char not in "[]" else self.sequence
                continue
            if char == "\x1b":
                self.sequence = char
            elif char == "\r":
                self.x, self.wrap = 0, False
            elif char == "\n":
                self.newline()
                self.wrap = False
            elif char == "\b":
                self.x, self.wrap = max(0, self.x - 1), False
            elif char == "\t":
                self.x = min(self.columns - 1, (self.x // 8 + 1) * 8)
            elif ord(char) >= 32 and char != "\x7f":
                if unicodedata.combining(char):
                    if self.x:
                        self.cells[self.y][self.x - 1] += char
                    continue
                width = 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1
                if self.wrap or self.x + width > self.columns:
                    self.newline()
                    self.x, self.wrap = 0, False
                self.cells[self.y][self.x] = char
                if width == 2:
                    self.cells[self.y][self.x + 1] = ""
                self.x += width
                if self.x >= self.columns:
                    self.x, self.wrap = self.columns - 1, True
        return bytes(responses)

    def csi(self, arguments, command):
        if arguments.startswith(("?", ">", "!")):
            return b""
        try:
            params = [int(value or "0") for value in arguments.split(";")]
        except ValueError:
            return b""
        value = params[0]
        count = value or 1
        if command == "n" and value == 6:
            return f"\x1b[{self.y + 1};{self.x + 1}R".encode()
        if command in "ABCDEFGHf`d":
            self.wrap = False
        if command == "A":
            self.y = max(0, self.y - count)
        elif command in "Be":
            self.y = min(self.rows - 1, self.y + count)
        elif command in "Ca":
            self.x = min(self.columns - 1, self.x + count)
        elif command == "D":
            self.x = max(0, self.x - count)
        elif command in "G`":
            self.x = min(self.columns - 1, count - 1)
        elif command in "Hf":
            self.y = min(self.rows - 1, count - 1)
            self.x = min(self.columns - 1, (params[1] if len(params) > 1 else 1) - 1)
        elif command == "d":
            self.y = min(self.rows - 1, count - 1)
        elif command == "K":
            start, end = (0, self.columns) if value == 2 else ((0, self.x + 1) if value == 1 else (self.x, self.columns))
            self.cells[self.y][start:end] = [" "] * (end - start)
        elif command == "J":
            if value == 2:
                self.cells = [[" "] * self.columns for _ in range(self.rows)]
            elif value == 0:
                self.cells[self.y][self.x:] = [" "] * (self.columns - self.x)
                for row in range(self.y + 1, self.rows):
                    self.cells[row] = [" "] * self.columns
        elif command == "P":
            row = self.cells[self.y]
            self.cells[self.y] = (row[:self.x] + row[self.x + count:] + [" "] * count)[:self.columns]
        elif command == "@":
            row = self.cells[self.y]
            self.cells[self.y] = (row[:self.x] + [" "] * count + row[self.x:])[:self.columns]
        elif command == "s":
            self.saved = self.x, self.y
        elif command == "u":
            self.x, self.y = self.saved
        return b""
