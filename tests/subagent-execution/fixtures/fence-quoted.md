# Plan that quotes the task format in a fence, indented

## T1: Types

The format, quoted with its lines indented so that no task heading or Depends
on line starts in column 0:

```markdown
  ## T9: Not a task
  **Depends on:** nothing
```

**Depends on:** nothing

## T2: Parser

~~~
def parse(text): ...
~~~

**Depends on:** T1
