// Envio de teste do resumo de Vendas Hoje por e-mail (Resend).
// Só o perfil BI pode chamar. Os números vêm de bi_vendas_hoje chamada com o token de quem pediu (escopo dele).
// Não grava nada no banco. Secrets: RESEND_API_KEY; opcional RELATORIO_REMETENTE (padrão onboarding@resend.dev).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// sem domínio próprio verificado: remetente de teste do Resend (só entrega para o e-mail dono da conta Resend)
const REMETENTE = Deno.env.get("RELATORIO_REMETENTE") || "onboarding@resend.dev";
const ORDEM = ["TATUAPE", "IPIRANGA", "JOAO DIAS", "SBC", "CAMPINAS", "RIO PRETO", "RIBEIRAO"];
const CANAIS: [string, string][] = [["ATACADO", "Atacado"], ["ECOMMERCE", "E-commerce"], ["OFICINA", "Oficina"], ["ACESSORIOS", "Acessórios"]];

function cors(resp: Response) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Headers", "authorization, x-client-info, apikey, content-type");
  resp.headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  return resp;
}
function json(obj: unknown, status = 200) {
  return cors(new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } }));
}
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const brl = (v: number) => "R$ " + Math.round(v).toLocaleString("pt-BR");
const pct = (v: number | null) => v === null || !isFinite(v) ? "—" : v.toFixed(1).replace(".", ",") + "%";
const dm = (iso: string) => iso.slice(8, 10) + "/" + iso.slice(5, 7);

type Soma = { f: number; l: number };
const z = (): Soma => ({ f: 0, l: 0 });
const mg = (o: Soma) => o.f > 0 ? o.l / o.f * 100 : null;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return cors(new Response("ok"));
  if (req.method !== "POST") return json({ error: "Método não permitido" }, 405);
  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const caller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: u, error: uErr } = await caller.auth.getUser();
    if (uErr || !u?.user) return json({ error: "Não autenticado" }, 401);
    const { data: perfil } = await admin.from("profiles").select("role, active").eq("id", u.user.id).maybeSingle();
    if (!perfil?.active || perfil.role !== "bi") return json({ error: "Só o perfil BI pode enviar o teste." }, 403);

    const chave = Deno.env.get("RESEND_API_KEY");
    if (!chave) return json({ error: "Falta cadastrar a chave do Resend nos secrets das funções (RESEND_API_KEY)." }, 503);

    const body = await req.json().catch(() => ({}));
    const para = String(body?.para ?? "").trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(para)) return json({ error: "E-mail de destino inválido." }, 400);

    // vendas do mês até o último dia com venda, no escopo de quem pediu
    const { data: d, error: vErr } = await caller.rpc("bi_vendas_hoje", { f: {}, dia: null });
    if (vErr) return json({ error: "Erro ao ler as vendas: " + vErr.message }, 500);
    const dia = String(d?.dia ?? "").slice(0, 10);
    const linhas: unknown[][] = d?.linhas ?? [];
    if (!dia || !linhas.length) return json({ error: "Sem vendas no mês para montar o resumo." }, 400);

    const { data: dims } = await admin.from("bi_dim").select("id, tipo, valor").in("tipo", ["loja", "canal", "tipo_cliente"]);
    const nome: Record<string, Record<number, string>> = {};
    for (const x of dims ?? []) (nome[x.tipo] ??= {})[x.id] = x.valor;

    let ontem = "";
    for (const r of linhas) { const ds = String(r[0]).slice(0, 10); if (ds < dia && ds > ontem) ontem = ds; }
    // A[loja][canal] = hoje, ontem, mês
    const A: Record<string, Record<string, { h: Soma; o: Soma; m: Soma }>> = {};
    for (const r of linhas) {
      const ds = String(r[0]).slice(0, 10), loja = nome.loja?.[Number(r[1])] || "N/D";
      const canal = String(nome.canal?.[Number(r[3])] || "").toUpperCase(), f = Number(r[5]) / 100, l = Number(r[6]) / 100;
      const x = ((A[loja] ??= {})[canal] ??= { h: z(), o: z(), m: z() });
      if (ds === dia) { x.h.f += f; x.h.l += l; }
      if (ds === ontem) { x.o.f += f; x.o.l += l; }
      x.m.f += f; x.m.l += l;
    }
    const soma = (lojas: string[], canais: string[]) => {
      const t = { h: z(), o: z(), m: z() };
      for (const lj of lojas) for (const c of canais) {
        const x = A[lj]?.[c]; if (!x) continue;
        for (const k of ["h", "o", "m"] as const) { t[k].f += x[k].f; t[k].l += x[k].l; }
      }
      return t;
    };
    const todas = Object.keys(A);
    const lojas = todas.filter((l) => (A[l].ATACADO?.m.f ?? 0) > 0.5)
      .sort((a, b) => ((ORDEM.indexOf(a) + 1 || 99) - (ORDEM.indexOf(b) + 1 || 99)) || a.localeCompare(b, "pt-BR"));
    const grupo = soma(todas, CANAIS.map((c) => c[0]));

    const td = "padding:7px 10px;border-bottom:1px solid #e5e7eb;text-align:right;white-space:nowrap;";
    const th = "padding:7px 10px;background:#f1f5f9;text-align:right;font-size:12px;color:#475569;";
    const cel = (o: Soma) => `<td style="${td}">${o.f > 0.5 ? brl(o.f) : "—"}<br><span style="font-size:11px;color:#64748b">${o.f > 0.5 ? "mg " + pct(mg(o)) : ""}</span></td>`;
    const linha = (rot: string, t: { h: Soma; o: Soma; m: Soma }, forte = false) =>
      `<tr${forte ? ' style="font-weight:700;background:#f8fafc"' : ""}><td style="${td}text-align:left">${esc(rot)}</td>${cel(t.h)}${cel(t.o)}${cel(t.m)}</tr>`;
    const cab = `<tr><th style="${th}text-align:left">&nbsp;</th><th style="${th}">Hoje (${dm(dia)})</th><th style="${th}">Ontem${ontem ? " (" + dm(ontem) + ")" : ""}</th><th style="${th}">Mês</th></tr>`;
    const tabela = (titulo: string, corpo: string) =>
      `<h3 style="font-size:15px;margin:22px 0 6px;color:#0f172a">${titulo}</h3><table cellspacing="0" cellpadding="0" style="border-collapse:collapse;width:100%;font-size:13px;color:#0f172a">${cab}${corpo}</table>`;

    const porCanal = CANAIS.map(([k, r]) => { const t = soma(todas, [k]); return t.m.f > 0.5 ? linha(r, t) : ""; }).join("") + linha("Todos os canais", grupo, true);
    const porLoja = lojas.map((l) => linha(l, soma([l], ["ATACADO"]))).join("") + linha("Atacado · total", soma(lojas, ["ATACADO"]), true);
    const kpi = (rot: string, v: string, sub: string) =>
      `<td style="padding:12px 14px;border:1px solid #e5e7eb;border-radius:10px;width:33%"><div style="font-size:11px;color:#64748b;text-transform:uppercase;letter-spacing:.06em">${rot}</div><div style="font-size:22px;font-weight:800;margin-top:4px">${v}</div><div style="font-size:12px;color:#475569">${sub}</div></td>`;
    const html = `<!doctype html><html><body style="margin:0;background:#f8fafc;font-family:Arial,Helvetica,sans-serif">
<div style="max-width:680px;margin:0 auto;padding:20px;background:#ffffff">
<div style="font-size:12px;color:#64748b">Nova Chevrolet BI · e-mail de teste</div>
<h2 style="margin:4px 0 14px;font-size:20px;color:#0f172a">Vendas de ${dm(dia)}</h2>
<table cellspacing="8" cellpadding="0" style="width:100%"><tr>
${kpi("Hoje · grupo", brl(grupo.h.f), "margem " + pct(mg(grupo.h)))}
${kpi("Ontem", brl(grupo.o.f), "margem " + pct(mg(grupo.o)))}
${kpi("Mês até agora", brl(grupo.m.f), "margem " + pct(mg(grupo.m)))}
</tr></table>
${tabela("Por canal", porCanal)}
${tabela("Atacado por loja", porLoja)}
<p style="font-size:11px;color:#64748b;margin-top:18px">Dados até ${dm(dia)}, no acesso de quem enviou. E-commerce pela loja. Os números completos, com média diária e projeção, estão no painel.</p>
</div></body></html>`;

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": "Bearer " + chave, "Content-Type": "application/json" },
      body: JSON.stringify({ from: `Nova Chevrolet BI <${REMETENTE}>`, to: [para], subject: `Vendas de ${dm(dia)} · teste`, html }),
    });
    const out = await r.json().catch(() => ({}));
    if (!r.ok) return json({ error: "O Resend recusou o envio: " + (out?.message || r.status) }, 502);
    return json({ ok: true, id: out?.id, para, dia });
  } catch (e) {
    return json({ error: "Falha ao enviar: " + String((e as Error)?.message ?? e) }, 500);
  }
});
