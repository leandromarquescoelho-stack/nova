// Resumo de Vendas Hoje por e-mail (Resend). Três jeitos de chamar:
//  1. {para}                       perfil BI logado: teste, com o escopo de quem pediu, sem filtros.
//  2. {agenda_id}                  perfil BI logado: "Enviar agora" de um agendamento (Configurações).
//  3. {agenda_id, slot, token}     pg_cron (private.bi_relatorio_disparar): envio agendado; o token é o segredo do Vault.
// Nos agendamentos, os números vêm de bi_relatorio_vendas com o acesso de quem criou o agendamento e os filtros salvos.
// Grava só o resultado do envio em bi_relatorio_envio. Publicar com verify_jwt = false (o pg_cron não manda JWT;
// a função confere o login ou o token). Secrets: RESEND_API_KEY; opcional RELATORIO_REMETENTE (padrão onboarding@resend.dev).
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

type Saida = { html: string; dia: string } | { erro: string };
// monta o e-mail a partir do retorno de bi_vendas_hoje
async function montar(admin: ReturnType<typeof createClient>, d: any, titulo: string, filtrosTxt: string, rodape: string): Promise<Saida> {
    const dia = String(d?.dia ?? "").slice(0, 10);
    const linhas: unknown[][] = d?.linhas ?? [];
    if (!dia || !linhas.length) return { erro: "Sem vendas no mês para montar o resumo." };
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
<div style="font-size:12px;color:#64748b">${esc(titulo)}</div>
<h2 style="margin:4px 0 14px;font-size:20px;color:#0f172a">Vendas de ${dm(dia)}</h2>
<table cellspacing="8" cellpadding="0" style="width:100%"><tr>
${kpi("Hoje · grupo", brl(grupo.h.f), "margem " + pct(mg(grupo.h)))}
${kpi("Ontem", brl(grupo.o.f), "margem " + pct(mg(grupo.o)))}
${kpi("Mês até agora", brl(grupo.m.f), "margem " + pct(mg(grupo.m)))}
</tr></table>
${tabela("Por canal", porCanal)}
${tabela("Atacado por loja", porLoja)}
${filtrosTxt ? `<p style="font-size:12px;color:#475569;margin:0 0 6px">Filtros: ${esc(filtrosTxt)}</p>` : ""}<p style="font-size:11px;color:#64748b;margin-top:18px">Dados até ${dm(dia)}, ${esc(rodape)}. E-commerce pela loja. Os números completos, com média diária e projeção, estão no painel.</p>
</div></body></html>`;

    return { html, dia };
}

async function enviar(chave: string, para: string[], assunto: string, html: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": "Bearer " + chave, "Content-Type": "application/json" },
    body: JSON.stringify({ from: `Nova Chevrolet BI <${REMETENTE}>`, to: para, subject: assunto, html }),
  });
  const out = await r.json().catch(() => ({}));
  return r.ok ? { ok: true as const, id: out?.id } : { ok: false as const, erro: "O Resend recusou o envio: " + (out?.message || r.status) };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return cors(new Response("ok"));
  if (req.method !== "POST") return json({ error: "Método não permitido" }, 405);
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const body = await req.json().catch(() => ({}));
  const agendaId = Number(body?.agenda_id) || null;
  const slot: string | null = body?.slot ? String(body.slot) : null;
  const marcar = async (status: string, detalhe: string) => {
    if (agendaId && slot) await admin.from("bi_relatorio_envio").update({ status, detalhe: detalhe.slice(0, 500) }).eq("agenda_id", agendaId).eq("slot", slot);
  };
  try {
    // quem chama: pg_cron (token) ou usuário BI logado
    let viaCron = false;
    if (body?.token) {
      const { data: ok } = await admin.rpc("bi_relatorio_token_ok", { t: String(body.token) });
      if (ok !== true || !agendaId || !slot) return json({ error: "Token inválido" }, 401);
      viaCron = true;
    }
    let caller: ReturnType<typeof createClient> | null = null;
    if (!viaCron) {
      const authHeader = req.headers.get("Authorization") ?? "";
      caller = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
      const { data: u, error: uErr } = await caller.auth.getUser();
      if (uErr || !u?.user) return json({ error: "Não autenticado" }, 401);
      const { data: perfil } = await admin.from("profiles").select("role, active").eq("id", u.user.id).maybeSingle();
      if (!perfil?.active || perfil.role !== "bi") return json({ error: "Só o perfil BI pode enviar." }, 403);
    }

    const chave = Deno.env.get("RESEND_API_KEY");
    if (!chave) { await marcar("erro", "falta RESEND_API_KEY"); return json({ error: "Falta cadastrar a chave do Resend nos secrets das funções (RESEND_API_KEY)." }, 503); }

    // 1. teste avulso
    if (!agendaId) {
      const para = String(body?.para ?? "").trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(para)) return json({ error: "E-mail de destino inválido." }, 400);
      const { data: d, error: vErr } = await caller!.rpc("bi_vendas_hoje", { f: {}, dia: null });
      if (vErr) return json({ error: "Erro ao ler as vendas: " + vErr.message }, 500);
      const m = await montar(admin, d, "Nova Chevrolet BI · e-mail de teste", "", "no acesso de quem enviou");
      if ("erro" in m) return json({ error: m.erro }, 400);
      const e = await enviar(chave, [para], `Vendas de ${dm(m.dia)} · teste`, m.html);
      if (!e.ok) return json({ error: e.erro }, 502);
      return json({ ok: true, id: e.id, para: [para], dia: m.dia });
    }

    // 2 e 3. agendamento
    const { data: ag } = await admin.from("bi_relatorio_agenda").select("*").eq("id", agendaId).maybeSingle();
    if (!ag) { await marcar("erro", "agendamento não encontrado"); return json({ error: "Agendamento não encontrado." }, 404); }
    if (viaCron && !ag.ativo) { await marcar("erro", "agendamento desativado"); return json({ error: "Agendamento desativado." }, 409); }
    const { data: d, error: vErr } = await admin.rpc("bi_relatorio_vendas", { p_uid: ag.dono, f: ag.filtros ?? {} });
    if (vErr) { await marcar("erro", "vendas: " + vErr.message); return json({ error: "Erro ao ler as vendas: " + vErr.message }, 500); }
    const m = await montar(admin, d, "Nova Chevrolet BI · " + (ag.nome || "Resumo de vendas"), ag.filtros_txt || "", "no acesso de quem criou o agendamento");
    if ("erro" in m) { await marcar("erro", m.erro); return json({ error: m.erro }, 400); }
    const e = await enviar(chave, ag.para, `${ag.nome || "Vendas"} · ${dm(m.dia)}`, m.html);
    if (!e.ok) { await marcar("erro", e.erro); return json({ error: e.erro }, 502); }
    await marcar("ok", "enviado para " + ag.para.length + " destinatário(s) · dados de " + dm(m.dia));
    return json({ ok: true, id: e.id, para: ag.para, dia: m.dia });
  } catch (e) {
    const t = String((e as Error)?.message ?? e);
    await marcar("erro", t).catch(() => {});
    return json({ error: "Falha ao enviar: " + t }, 500);
  }
});
