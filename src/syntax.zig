fn repeat(comptime char: u8, comptime count: usize) []const u8 {
    comptime {
        var result: [count]u8 = undefined;

        for (0..count) |i| {
            result[i] = char;
        }

        return &result;
    }
}

fn generateSystemVarName(comptime field_name: []const u8) []const u8 {
    return "SYSTEM." ++ field_name;
}

fn generateTag(
    comptime keyword: []const u8,
    comptime has_condition: bool,
) []const u8 {
    comptime {
        if (has_condition) {
            return TAG_START ++ " " ++ keyword ++ " CONDITION " ++ TAG_END;
        } else {
            return TAG_START ++ " " ++ keyword ++ " " ++ TAG_END;
        }
    }
}

fn getSystemVarDescription(comptime system_var: SYSTEM) []const u8 {
    return switch (system_var) {
        .os => "Operating system",
        .arch => "CPU architecture",
        .hostname => "Machine hostname",
        .desktop => "Desktop environment (lowercase)",
    };
}

fn getExampleValue(comptime system_var: SYSTEM) []const u8 {
    return switch (system_var) {
        .os => "freebsd",
        .arch => "x86_64",
        .hostname => "gibson",
        .desktop => "gnome",
    };
}

fn getOperatorDescription(comptime op: []const u8) []const u8 {
    comptime {
        if (std.mem.eql(u8, op, "==")) {
            return "Equality comparison";
        } else {
            return "Inequality comparison";
        }
    }
}

fn generateSystemVariablesSection() []const u8 {
    comptime {
        var result: []const u8 = "System variables:\n";
        const fields = @typeInfo(SYSTEM).@"enum".fields;

        for (fields) |field| {
            const var_name = generateSystemVarName(field.name);
            const desc = getSystemVarDescription(@field(SYSTEM, field.name));
            const padding = repeat(' ', 18 - var_name.len);
            result = result ++ "  " ++ var_name ++ padding ++ desc ++ "\n";
        }

        return result;
    }
}

fn generateOperatorsSection() []const u8 {
    comptime {
        const ops = [_][]const u8{ "==", "!=" };
        var result: []const u8 = "Operators:\n";

        for (ops) |op| {
            const desc = getOperatorDescription(op);
            result = result ++ "  " ++ op ++ "    " ++ desc ++ "\n";
        }

        return result;
    }
}

fn generateConditionExamples() []const u8 {
    comptime {
        var result: []const u8 = "  Examples:\n";
        const ops = [_][]const u8{ "==", "!=" };
        const fields = @typeInfo(SYSTEM).@"enum".fields;

        for (fields, 0..) |field, idx| {
            if (idx < ops.len) {
                const var_name = generateSystemVarName(field.name);
                const example_val = getExampleValue(@field(SYSTEM, field.name));
                const op = ops[idx];
                result = result ++ "    " ++
                    var_name ++ " " ++ op ++ " " ++ example_val ++ "\n";
            }
        }

        return result;
    }
}

fn generateConditionalStatementsSection() []const u8 {
    comptime {
        const section_header = "Conditional statements:\n";

        const if_line = "  " ++ generateTag("if", true) ++ "\n" ++
            "    content when condition is true\n";

        const elif_line = "  " ++ generateTag("elif", true) ++ "\n" ++
            "    content when previous conditions false and this is true\n";

        const else_line = "  " ++ generateTag("else", false) ++ "\n" ++
            "    content when all conditions are false\n";

        const end_line = "  " ++ generateTag("end", false) ++ "\n" ++
            "    closes the conditional block\n";

        return section_header ++ if_line ++ elif_line ++ else_line ++ end_line;
    }
}

fn generateNestingSection() []const u8 {
    comptime {
        const header = "Nesting:\n" ++
            "  Conditionals can be nested to any depth\n\n" ++
            "  Example:\n";

        const line1 = "    " ++ TAG_START ++ " if SYSTEM.os == openbsd " ++
            TAG_END ++ "\n";

        const line2 = "      " ++ TAG_START ++ " if SYSTEM.arch == x86_64 " ++
            TAG_END ++ "\n";

        const line3 = "        content for openbsd on x86_64\n";
        const line4 = "      " ++ TAG_START ++ " end " ++ TAG_END ++ "\n";
        const line5 = "    " ++ TAG_START ++ " end " ++ TAG_END ++ "\n";

        return header ++ line1 ++ line2 ++ line3 ++ line4 ++ line5;
    }
}

fn generateExamplesSection() []const u8 {
    comptime {
        const fields = @typeInfo(SYSTEM).@"enum".fields;
        const first_var = fields[0].name;
        const example_val = getExampleValue(@field(SYSTEM, first_var));

        const header = "Usage:\n  Simple conditional:\n";

        const line1 = "    " ++ TAG_START ++ " if SYSTEM." ++ first_var ++
            " == " ++ example_val ++ " " ++ TAG_END ++ "\n";

        const line2 = "    config_" ++ example_val ++ "=\"enabled\"\n";
        const line3 = "    " ++ TAG_START ++ " else " ++ TAG_END ++ "\n";
        const line4 = "    config_default=\"enabled\"\n";
        const line5 = "    " ++ TAG_START ++ " end " ++ TAG_END ++ "\n\n";

        const multi_header = "  Multiple conditions:\n";
        const multi1 = "    " ++ TAG_START ++ " if SYSTEM." ++ first_var ++
            " == value1 " ++ TAG_END ++ "\n";

        const multi2 = "    option=\"first\"\n";
        const multi3 = "    " ++ TAG_START ++ " elif SYSTEM." ++ first_var ++
            " == value2 " ++ TAG_END ++ "\n";

        const multi4 = "    option=\"second\"\n";
        const multi5 = "    " ++ TAG_START ++ " else " ++ TAG_END ++ "\n";
        const multi6 = "    option=\"other\"\n";
        const multi7 = "    " ++ TAG_START ++ " end " ++ TAG_END ++ "\n\n";

        const inline_header = "  Inline conditionals:\n";
        const inline1 = "    value=\"" ++ TAG_START ++
            " if SYSTEM.os == freebsd " ++ TAG_END ++ "FBSD" ++
            TAG_START ++ " else " ++ TAG_END ++ "OTHER" ++ TAG_START ++
            " endif " ++ TAG_END;

        return header ++ line1 ++ line2 ++ line3 ++ line4 ++ line5 ++
            multi_header ++ multi1 ++ multi2 ++ multi3 ++ multi4 ++ multi5 ++
            multi6 ++ multi7 ++ inline_header ++ inline1;
    }
}

const summary_text = summ: {
    const tag_delimiters = "Tag delimiters:\n" ++
        "  " ++ TAG_START ++ " ... " ++ TAG_END ++ "    Template tag markers\n";

    const conditional_statements = generateConditionalStatementsSection();
    const system_variables = generateSystemVariablesSection();
    const operators = generateOperatorsSection();

    const condition_format = "Condition format:\n" ++
        "  variable OPERATOR value\n\n";

    const condition_examples = generateConditionExamples();
    const nesting = generateNestingSection();
    const examples = generateExamplesSection();

    break :summ tag_delimiters ++ "\n" ++
        conditional_statements ++ "\n" ++
        system_variables ++ "\n" ++
        operators ++ "\n" ++
        condition_format ++
        condition_examples ++ "\n" ++
        nesting ++ "\n" ++
        examples ++ "\n";
};

fn indentText(
    comptime text: []const u8,
    comptime indent: []const u8,
) []const u8 {
    @setEvalBranchQuota(std.math.maxInt(u32));
    comptime {
        if (indent.len == 0) {
            return text;
        }

        var result: []const u8 = "";
        var line_start: usize = 0;

        for (text, 0..) |char, i| {
            if (char == '\n') {
                const line = text[line_start..i];

                if (line.len > 0) {
                    result = result ++ indent ++ line;
                }

                result = result ++ "\n";

                line_start = i + 1;
            }
        }

        // handle the last line if it does not end with a new line
        if (line_start < text.len) {
            const line = text[line_start..];

            if (line.len > 0) {
                result = result ++ indent ++ line;
            }
        }

        return result;
    }
}

pub fn getSummary(comptime indent: []const u8) []const u8 {
    return comptime indentText(summary_text, indent);
}

test getSummary {
    const summary = getSummary("");
    try std.testing.expect(summary.len > 0);
}

test "summary with indent" {
    const summary = getSummary("    ");

    try std.testing.expect(summary.len > 0);

    var iter = std.mem.splitScalar(u8, summary, '\n');
    var line_count: usize = 0;

    while (iter.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, line, "    "));
        }

        line_count += 1;
    }

    try std.testing.expect(line_count > 1);
}

test "summary with tab indent" {
    const summary = getSummary("\t");

    try std.testing.expect(summary.len > 0);

    var iter = std.mem.splitScalar(u8, summary, '\n');

    while (iter.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(std.mem.startsWith(u8, line, "\t"));
        }
    }
}

const std = @import("std");
const lib = @import("libdfs");
const TAG_START = lib.TAG_START;
const TAG_END = lib.TAG_END;
const SYSTEM = lib.SYSTEM;
