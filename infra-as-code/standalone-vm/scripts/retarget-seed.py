# Re-target the official HCM 2.1 seed dump (tenant "mz", schema public) to a
# central-instance env (tenant TENANT, mdms/product tables in schema SCHEMA).
import re, sys
src, dst, TENANT, SCHEMA = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
to_schema = {"eg_mdms_data", "eg_mdms_schema_definition", "product", "product_variant"}
json_cols = {"data", "definition", "additionaldetails", "variation", "boundaryhierarchy"}
cols = None; n = 0
out = open(dst, "w")
for line in open(src):
    m = re.match(r"COPY public\.(\w+) \((.*)\) FROM stdin;", line)
    if m:
        table = m.group(1); cols = [c.strip() for c in m.group(2).split(",")]
        if table in to_schema:
            line = line.replace("COPY public.", "COPY %s." % SCHEMA, 1)
        out.write(line); continue
    if cols is not None:
        if line.startswith("\\."):
            cols = None; out.write(line); continue
        f = line.rstrip("\n").split("\t")
        for i, c in enumerate(cols):
            if c == "tenantid" and f[i] == "mz":
                f[i] = TENANT; n += 1
            elif c in json_cols:
                f[i] = f[i].replace('"mz"', '"%s"' % TENANT).replace('"mz.', '"%s.' % TENANT)
        out.write("\t".join(f) + "\n"); continue
    out.write(line)
out.close()
print("tenant cells rewritten:", n)
