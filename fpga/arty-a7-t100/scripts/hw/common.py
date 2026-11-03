"""Tcl argument quoting shared by hardware batch generators."""


def tcl_string(value):
    escapes = {"\\": "\\\\", '"': '\\"', "$": "\\$", "[": "\\[", "]": "\\]",
               "\n": "\\n", "\r": "\\r", "\t": "\\t"}
    return '"' + "".join(escapes.get(char, char) for char in str(value)) + '"'
