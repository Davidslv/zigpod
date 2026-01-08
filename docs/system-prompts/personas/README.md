# Expert Review Personas

This folder contains specialized AI personas for comprehensive code review and quality assurance of ZigPod. Each persona brings a specific expertise focus, ensuring production-ready, state-of-the-art quality.

## Available Personas

| # | Persona | Focus | Use When |
|---|---------|-------|----------|
| 01 | [Embedded QA Engineer](01-embedded-qa-engineer.md) | Hardware correctness, timing, edge cases | Reviewing drivers, kernel code |
| 02 | [Security Auditor](02-security-auditor.md) | Memory safety, input validation | Reviewing external data handling |
| 03 | [UX Designer](03-ux-designer.md) | Usability, accessibility | Designing UI, navigation |
| 04 | [Performance Engineer](04-performance-engineer.md) | CPU, memory, latency, power | Optimizing critical paths |
| 05 | [Audio Engineer](05-audio-engineer.md) | Audio quality, codecs, playback | Reviewing audio pipeline |
| 06 | [Zig Language Expert](06-zig-language-expert.md) | Idioms, error handling, comptime | Code quality review |
| 07 | [Test Engineer](07-test-engineer.md) | Coverage, mocking, automation | Improving test suite |
| 08 | [Technical Writer](08-technical-writer.md) | Documentation, clarity | Documenting APIs |

## How to Use

### Single Persona Review
```
Using the [Persona Name] persona, review [file or component] for [specific focus].
```

### Multi-Persona Comprehensive Review

For critical components, use multiple personas in sequence:

1. **Embedded QA Engineer** - Verify correctness
2. **Security Auditor** - Check for vulnerabilities
3. **Performance Engineer** - Optimize critical paths
4. **Test Engineer** - Ensure adequate coverage
5. **Zig Language Expert** - Polish code quality

### Review Checklist Template

```markdown
## Component Review: [name]

### QA Review
- [ ] Hardware interaction correct
- [ ] Edge cases handled
VERDICT: ___

### Security Review
- [ ] Input validation complete
- [ ] No memory safety issues
POSTURE: ___

### Performance Review
- [ ] Meets latency requirements
- [ ] Memory usage acceptable
GRADE: ___

### FINAL VERDICT: Ready for Production / Needs Work / Block
```

## Rating Scales

Each persona uses a consistent 4-level rating:

| Level | Meaning |
|-------|---------|
| Excellent/Strong/Polished | Production ready, exemplary |
| Good/Acceptable | Minor issues, acceptable for release |
| Needs Work/Needs Improvement | Significant issues to address |
| Block/Vulnerable/Unusable | Critical issues, do not proceed |
