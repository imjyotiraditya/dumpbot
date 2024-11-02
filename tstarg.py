from rich.console import Console

console = Console()


def test_option_parsing(args):
    console.print(f"\n[blue]Testing args:[/blue] {args}")

    options = "".join("".join(args[1:]).split())

    console.print(f"[yellow]Processed into:[/yellow] '{options}'")
    console.print("\n[green]Would set:[/green]")
    console.print(f"a: {'a' in options}")
    console.print(f"f: {'f' in options}")
    console.print(f"b: {'b' in options}")
    console.print(f"p: {'p' in options}")


tests = [
    ["url"],
    ["url", "a"],
    ["url", "a", "f", "b"],
    ["url", "afb"],
    ["url", "a", "fb", "p"],
    ["url", "a   ", "  fb", "p"],
]

for test in tests:
    test_option_parsing(test)
