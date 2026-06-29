# Data — Sovereign RAG

## Purpose
Sample corpus for demonstrating a sovereign RAG pipeline on RHOAI.
All documents are publicly available from official regulatory sources.
No customer data, no proprietary content.

## Suggested source documents

| Document | Source | Why it's relevant |
|---|---|---|
| RBNZ Capital Adequacy Framework (BS2) | rbnz.govt.nz | Prudential standard — dense, technical, real |
| RBNZ AML/CFT Guideline | rbnz.govt.nz | Compliance domain — good for Q&A demos |
| APRA CPS 230 Operational Risk | apra.gov.au | Cross-jurisdictional — shows breadth |
| APRA CPG 234 Information Security | apra.gov.au | Cyber/risk — resonates with CISO audience |
| BCBS 239 Principles (BIS) | bis.org | International standard — name recognition |

## Download instructions
Download PDFs manually from the sources above and place in `data/raw/`.
Do not commit PDFs to git (see .gitignore).
Document the exact URL and download date in the table below for reproducibility.

## Downloaded files

| Filename | Source URL | Downloaded |
|---|---|---|
| (populate when downloaded) | | |

## Pre-processing notes
- PDFs are chunked and embedded during notebook 01-ingest-and-embed.ipynb
- Chunk size: 512 tokens, 50-token overlap (adjustable in notebook)
- Embedding model: all-MiniLM-L6-v2 (runs CPU-side in the workbench, no GPU needed)
