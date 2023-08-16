Thank you for thinking about contributing something to TruffleRuby!

## Building

See the [building instructions](doc/contributor/workflow.md) to build TruffleRuby from source.

## Contributor Agreement

You will need to sign the [Oracle Contributor Agreement](https://www.oracle.com/technical-resources/oracle-contributor-agreement.html)
(using an online form) for us to able to review and merge your work.

See [Contribute to GraalVM](https://www.graalvm.org/community/contributors/#ii-sign-the-oracle-contributor-agreement)
for more details.

We also have a [code of conduct for contributors](http://www.graalvm.org/community/conduct/).

## Contributor Documentation

And finally, we have some more technical contributor documentation, which might
be useful to someone working on TruffleRuby.

https://github.com/oracle/truffleruby/tree/master/doc/contributor

## Slack

You are welcome to join the channel `#truffleruby` of the
[GraalVM Slack](https://www.graalvm.org/community/#community-support)
for any help related to contributing to TruffleRuby.

## Style

We use various lint tools to keep the style consistent.
The most important checks can be run locally with `jt lint fast`.
You can use `tool/hooks/lint-check.sh` as a git hook to run `jt lint fast` automatically, see instructions in that file.

## ChangeLog

When opening a Pull Request, if the change is visible or meaningful to users (they are the intended readers of the ChangeLog),
please add a ChangeLog entry with this format:

```
* Description (#GitHub issue number if any, @author).
```

See the [the ChangeLog](CHANGELOG.md) for examples.

This is the meaning of the sections in the ChangeLog:
* New features: a big new feature or a new method provided by TruffleRuby which does not exist in CRuby (e.g. a new interop method).
* Compatibility: any change which helps compatibility with CRuby, whether it is a new method or behavior closer to CRuby.
* Bug fixes: only for fixes where the bug "silently" caused incorrect behavior.
  For example, if it raised an exception before, the wrong behavior was pretty clear, so it should be under `Compatibility` not `Bug fixes`.
  On the other hand, if e.g. `1 + 2` returned `4` that should be under `Bug fixes`.
* Performance: something which improves performance (whether interpreter, warmup or peak).
* Memory Footprint: something which improves memory footprint.
* Changes: this means incompatible changes that users may need to adapt to.

Always keep an empty line around the various sections, like it is done for entries in older releases.
The idea is only add lines, never remove lines (important since this file uses union merge).

GitHub might show on the Pull Request:
```
Conflicting files
CHANGELOG.md
```
This is a bug in GitHub's UI, there is never any conflict as `CHANGELOG.md` uses union merge.
Please do not use the `Resolve conflicts` button as that will create a redundant merge commit.
