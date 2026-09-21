# 002 — Subnet-SNAT förblir påslaget, och hur CI når primary

**Status:** gällande. Ersätter utkastet i `001-direkt-routing-utan-snat.md`,
som aldrig mergades eller applicerades.

## Läget

Jumphosten annonserar `10.0.4.0/24` och rutten är godkänd i Headscale.
Tailscale SNAT:ar subnet-routad trafik som standard, och jumphosten kör med
den standarden:

```
NoSNAT: false
AdvertiseRoutes: ['10.0.4.0/24', '10.0.0.2/32']
```

Beslut 001 föreslog att slå av SNAT för att kunna släppa in teamet per person
i brandväggen. Det landade aldrig. Under tiden skrevs ändå
`allow_primary_http` som om SNAT vore avslaget: källan var bara
`team_tailnet_cidrs`, med kommentaren "Subnet routing will have to be off for
this to work". Regeln var därmed verkningslös — port 8000 var i praktiken
stängd för alla utom jumphosten själv.

## Beslut

SNAT förblir påslaget. Brandväggsregler mot `primary` använder
`local.subnet_cidr` som källa, inte tailnet-adresser.

## Konsekvenser

All tailnet-trafik kommer fram till primary som `10.0.4.2`. Det betyder:

- **Ingen åtkomstkontroll per person mot primary.** Alla i tailnetet som
  accepterar rutter ser likadana ut i brandväggen. Det var hela poängen med
  001, och den poängen är fortfarande giltig — men ingen har slagit av SNAT,
  och halvfärdiga regler som förutsätter att det är gjort ger en falsk känsla
  av begränsning.
- **GitHub Actions-runnern behöver ingen egen post i `team_tailnet_cidrs`.**
  Den får en efemär tailnet-adress vid varje körning, men SNAT:as till
  `10.0.4.2` och täcks av `subnet_cidr` som alla andra.
- **Runnern måste köra `tailscale up --accept-routes`.** Utan den installeras
  aldrig subnet-rutten och 10.0.4.3 är helt oåtkomlig, vilket var det
  ursprungliga symptomet.

## Om ni vill ha kontroll per person

Slå av SNAT på jumphosten (`tailscale set --snat-subnet-routes=false`) och
lägg tillbaka `var.team_tailnet_cidrs` i `local.ssh_source_ranges`. Gör båda
i samma ändring. Görs bara det ena låser ni antingen ut teamet eller får
regler som inte begränsar något. Utkastet i 001 har detaljerna, inklusive att
primary måste kunna svara tillbaka till `100.64.0.x`.

CI blir då ett eget fall, eftersom en efemär adress inte kan förhandsgodkännas:
ge CI-användaren en fast tailnet-adress eller deploya via SSH genom jumphosten.
