import 'package:shared_preferences/shared_preferences.dart';
import '../modules/shared/module_config.dart';
import '../modules/sales/services/milestone_settings_service.dart';

/// Master switch for the sector-template ("business type") feature.
///
/// The feature is a pure config-override layer: every label getter
/// (`ModuleConfig.displayName`/`itemName`, `BusinessVocabulary.taskItemName`)
/// already falls back to the built-in defaults when no sector is active, and
/// the only things that can make a sector active are the pickers (which call
/// [BusinessVocabulary.set]) and the startup [BusinessVocabulary.load].
///
/// Flipping this to false hides those entry points, skips the load, and routes
/// onboarding past the sector step — the app then behaves exactly like the
/// pre-sector "General" build. The catalog and getters stay intact so
/// re-enabling is a one-line change and any persisted `business_type` (from
/// existing users) is preserved, never destroyed.
const bool kSectorTemplatesEnabled = false;

/// Per-module overrides contributed by a [SectorTemplate]. Null fields fall
/// back to the module's built-in [ModuleConfig] default; a null `milestones`
/// list means "don't touch this module's milestone template".
class SectorModule {
  /// Item noun shown throughout the module (e.g. "Job" instead of "Ticket").
  final String? itemName;

  /// Module title (AppBar / drawer). Null keeps the default display name.
  final String? displayName;

  /// Milestone titles to seed this module with, in pipeline order.
  final List<String>? milestones;

  /// Whether to force-enable milestones for this module (Task is opt-in).
  final bool enableMilestones;

  const SectorModule({
    this.itemName,
    this.displayName,
    this.milestones,
    this.enableMilestones = false,
  });
}

/// A "what does your business do?" preset. It relabels module vocabularies and
/// pre-seeds the milestone pipelines that fit the sector — a framing layer,
/// not new entities (it never adds scheduling / inventory the app lacks).
class SectorTemplate {
  final String id; // stable key persisted in prefs
  final String label; // shown in the picker
  final String blurb; // one-line description of the operating model
  /// Representative sub-sectors that collapse into this broad archetype, shown
  /// under the label so a user can self-identify ("AC, plumbing, CCTV, RO …").
  final String examples;

  /// Which module is the sector's FRONT DOOR — the one whose engine actually
  /// fits the work (a job = Service Teams ticket, an order = Sales enquiry,
  /// a matter/story/deliverable = a WorkTracker task). The app lands here on
  /// first launch, and it is the module that gets relabelled + seeded. Null
  /// means the WorkTracker default.
  final ModuleType homeModule;

  /// Default labels for the item's user-defined custom fields (slots 1..3),
  /// so a sector pre-names the fields that fit its workflow (e.g. AC service →
  /// "Unit / Asset No."). Applied only into EMPTY slots on selection and
  /// cleared again on General — a user's own labels are never overwritten, and
  /// values already typed on items are untouched (this only names the fields).
  final List<String> customFieldLabels;

  final Map<ModuleType, SectorModule> modules;

  /// Whether this sector appears as a CHOICE in the pickers. A broad archetype
  /// that a later concrete sector fully supersets is retired by setting this
  /// false: it stays in [SectorTemplates.all] so a user who already picked it
  /// keeps resolving its relabel + milestone seed, but new users are steered to
  /// the sharper option instead of two near-identical tiles.
  final bool pickerVisible;

  const SectorTemplate({
    required this.id,
    required this.label,
    required this.blurb,
    this.examples = '',
    this.homeModule = ModuleType.task,
    this.customFieldLabels = const [],
    this.modules = const {},
    this.pickerVisible = true,
  });

  SectorModule? moduleFor(ModuleType type) => modules[type];
}

/// A labelled block of sectors in the picker, grouped by the sector's
/// front-door module so the list reads as "what kind of work do you run?"
/// rather than one long flat list of overlapping archetypes.
class SectorGroup {
  final String title;
  final String subtitle;
  final List<SectorTemplate> sectors;

  const SectorGroup({
    required this.title,
    required this.subtitle,
    required this.sectors,
  });
}

/// Honest-fit sectors only — every relabel + milestone seed maps to a real,
/// working capability. "General" is the no-op default (exactly today's app).
///
/// These are deliberately BROAD operating archetypes, not per-sector presets:
/// dozens of MSME sub-sectors collapse into each one (the doc's own conclusion
/// — "the same engine can serve dozens of sectors without building separate
/// products"). The `examples` line lists representative sectors purely so a
/// user can self-identify; picking an archetype never claims a capability the
/// app doesn't have (no bookings, inventory, or scheduling is implied).
class SectorTemplates {
  SectorTemplates._();

  static const List<SectorTemplate> all = [
    // 0. The no-op default — horizontal, unchanged app, WorkTracker home.
    SectorTemplate(
      id: 'general',
      label: 'General / Other',
      blurb: 'Everyday task, enquiry and ticket tracking',
      examples: 'Any team, any workflow',
      homeModule: ModuleType.task,
    ),

    // ── SERVICE-LED front door: work is an inbound job that gets resolved ──
    // Field / on-site service — the single biggest MSME cluster (AC/HVAC,
    // electrical, plumbing, RO, CCTV, appliance, pest, IT SUPPORT, security
    // system installers). A technician job is a Service Teams ticket, so the
    // FRONT DOOR is the CRM module — NOT WorkTracker (a job has a status +
    // resolution a flat task can't express). WorkTracker keeps "Task" for
    // internal chores.
    SectorTemplate(
      id: 'field-service',
      label: 'Field Service & Repairs',
      blurb: 'Technician jobs, site visits and service cycles',
      examples: 'AC/HVAC · Electrical · Plumbing · RO/Water · CCTV · Appliance · Pest control · IT support · Security system installers',
      homeModule: ModuleType.crm,
      // Retired from the picker: superseded by the concrete AC/HVAC, CCTV/
      // Electrical/Solar, Repair and IT-support sectors below (same front door).
      pickerVisible: false,
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Job',
          milestones: [
            'Complaint Received',
            'Site Visit',
            'Quotation',
            'Work Scheduled',
            'Job Completed',
            'Payment Collected',
          ],
        ),
      },
    ),

    // ── SALES-LED front door: work is a funnel with a won/lost outcome ──
    // Sales & distribution — dealer / order pipeline with dispatch and
    // collections (building-material dealers, distributors, wholesalers,
    // trading/retail). An ORDER is a sales enquiry, so the FRONT DOOR is the
    // Sales module; the built-in sales milestones (quotation → payment →
    // handover) already fit, so no seed needed. Service side = complaints.
    SectorTemplate(
      id: 'distribution',
      label: 'Sales & Distribution',
      blurb: 'Orders, quotations, dispatch and collections',
      examples: 'Dealers · Distributors · Wholesalers · Trading / Retail',
      homeModule: ModuleType.sales,
      // Retired: superseded by the concrete Distributors & Wholesalers and
      // Building Material Dealers sectors (same front door).
      pickerVisible: false,
      modules: {
        ModuleType.sales: SectorModule(itemName: 'Order'),
        ModuleType.crm: SectorModule(itemName: 'Complaint'),
      },
    ),

    // ── WORKTRACKER-LED archetypes: the work is a flat matter/story/
    //    deliverable/activity with a deadline — NOT a funnel, NOT a ticket.
    //    These are the sectors where relabelling WorkTracker is genuinely
    //    correct, and each pre-seeds Task milestones (opt-in → force-enabled).

    // 1. Projects & site execution — multi-stage, deadline-heavy delivery.
    SectorTemplate(
      id: 'projects',
      label: 'Projects & Site Execution',
      blurb: 'Multi-stage delivery with site and vendor coordination',
      examples: 'Interior · Civil/MEP · Events · Fabrication · Signage · Fit-outs · IT implementation',
      homeModule: ModuleType.task,
      // Retired: superseded by the concrete Interior & Fit-out and Construction
      // / Civil Contractors sectors (same front door).
      pickerVisible: false,
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Activity',
          enableMilestones: true,
          milestones: [
            'Survey / Planning',
            'Mobilization',
            'Execution',
            'Finishing',
            'Snag List',
            'Handover',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Project'),
      },
    ),

    // 2. Design & creative studio — brief→design→review→deliver cycles.
    SectorTemplate(
      id: 'design',
      label: 'Design & Creative Studio',
      blurb: 'Client deliverables moving through review and approval',
      examples: 'Design teams · Fashion design · Brand/content studio · Ad creative · Product/UI design',
      homeModule: ModuleType.task,
      // Retired: superseded by the concrete Marketing / Creative / Digital
      // Agencies sector (same front door, same brief→delivery cycle).
      pickerVisible: false,
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Deliverable',
          enableMilestones: true,
          milestones: [
            'Brief',
            'Concept',
            'Draft',
            'Review',
            'Revision',
            'Final Delivery',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Brief'),
      },
    ),

    // 3. News & content desk — pitch→assign→draft→edit→publish workflow.
    SectorTemplate(
      id: 'news',
      label: 'News & Content Desk',
      blurb: 'Stories and content tracked from pitch to publish',
      examples: 'News / journalism · Media · Publishing · Content / SEO teams · Blogs / newsletters',
      homeModule: ModuleType.task,
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Story',
          enableMilestones: true,
          milestones: [
            'Pitch',
            'Assigned',
            'Draft',
            'Edit',
            'Approve',
            'Publish',
          ],
        ),
      },
    ),

    // 4. Consulting, legal & advisory — recurring client MATTERS (the daily
    //    work is a case/file, not a sale). CA/tax, lawyers, consultants,
    //    auditors. Front door is WorkTracker (a matter is flat tracked work);
    //    Sales stays for the client-acquisition funnel (relabeled Lead).
    SectorTemplate(
      id: 'consulting',
      label: 'Consulting, Legal & Advisory',
      blurb: 'Client matters and files tracked to delivery',
      examples: 'CA / Tax · Lawyers / legal · Consultants · Auditors · Architects · Brokers',
      homeModule: ModuleType.task,
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Matter',
          enableMilestones: true,
          milestones: [
            'Engagement Opened',
            'Inputs / Discovery',
            'Preparation',
            'Review',
            'Delivered / Filed',
            'Closed',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Lead'),
        ModuleType.crm: SectorModule(itemName: 'Request'),
      },
    ),

    // ── SITE/ASSET archetypes: sectors whose work revolves around a site or an
    //    installed asset. Every one is an honest fit for an existing engine
    //    (WorkTracker flat work or the CRM inbound queue) — no new capability is
    //    implied, just framing and per-module milestones.

    // 5. Property & facility — site-grouped upkeep work orders (WorkTracker-led:
    //    flat, deadline-driven jobs across many properties).
    SectorTemplate(
      id: 'property-facility',
      label: 'Property & Facility',
      blurb: 'Site upkeep and facility work orders across properties',
      examples: 'Property management · Facility management · Building upkeep · Housekeeping · Society / estate management',
      homeModule: ModuleType.task,
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Work Order',
          enableMilestones: true,
          milestones: [
            'Raised',
            'Assigned',
            'In Progress',
            'Completed',
            'Signed Off',
          ],
        ),
        ModuleType.crm: SectorModule(itemName: 'Complaint'),
      },
    ),

    // 6. Guarding & security ops — site-grouped deployments and incident
    //    response (CRM-led: an inbound request resolved through a status pipe).
    SectorTemplate(
      id: 'guarding-security',
      label: 'Guarding & Security Ops',
      blurb: 'Manned guarding deployments and incident response per site',
      examples: 'Security agencies · Event / bouncer security · Patrol & PSO · CCTV monitoring · Industrial security',
      homeModule: ModuleType.crm,
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Deployment',
          milestones: [
            'Request Received',
            'Guards Assigned',
            'Deployed On-Site',
            'On Duty',
            'Relieved',
            'Report Filed',
          ],
        ),
      },
    ),

    // 7. Equipment maintenance — asset-grouped preventive + breakdown service
    //    (CRM-led: a service call tracked to resolution and payment).
    SectorTemplate(
      id: 'equipment-maintenance',
      label: 'Equipment Maintenance',
      blurb: 'Preventive and breakdown maintenance of installed assets',
      examples: 'Generator upkeep · Elevator / lift maintenance · HVAC servicing · Machinery AMC · Fleet / vehicle maintenance',
      homeModule: ModuleType.crm,
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Service Visit',
          milestones: [
            'Call Received',
            'Asset Inspected',
            'Quote Approved',
            'Service Completed',
            'Payment Collected',
          ],
        ),
      },
    ),

    // ══════════════════════════════════════════════════════════════════════
    // Phase-2E — concrete SME sectors. Added on top of the broad archetypes
    // above (the catalog is a superset). Each entry is PURE CONFIG: a
    // front-door module + an item noun + a milestone seed for NEW items only.
    // No new entities: the customer / company / site are the existing
    // customerInfo fields, the assignee stays "Assignee", and recurring work
    // (where relevant) uses the shipped time-driven engine. Sectors whose
    // workflow implies a genuinely new object (asset registry, inventory,
    // first-class site) are framed honestly onto the closest module — the
    // missing capability is reported as a gap, NOT silently built.
    // ══════════════════════════════════════════════════════════════════════

    // ── SERVICE / CRM front door: an inbound job resolved through a pipe ──
    SectorTemplate(
      id: 'ac-hvac-service',
      label: 'AC / HVAC & Appliance Service',
      blurb: 'Service jobs, site visits and AMC maintenance cycles',
      examples: 'AC repair · HVAC · Fridge / washing-appliance service · Water purifier',
      homeModule: ModuleType.crm,
      customFieldLabels: ['Unit / Asset No.', 'Site / Area'],
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Service Job',
          milestones: [
            'Complaint Received',
            'Assigned to Technician',
            'Site Visit',
            'Waiting for Parts',
            'Job Completed',
            'Payment Collected',
          ],
        ),
      },
    ),

    SectorTemplate(
      id: 'cctv-electrical-solar',
      label: 'CCTV / Electrical / Solar Installation & Service',
      blurb: 'Installation jobs tracked from survey to handover',
      examples: 'CCTV · Electrical wiring · Solar rooftop · Inverter / UPS',
      homeModule: ModuleType.crm,
      customFieldLabels: ['Site / Location', 'Asset / System'],
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Installation Job',
          milestones: [
            'Enquiry',
            'Site Survey',
            'Quotation',
            'Installation',
            'Testing',
            'Handover',
            'Payment Collected',
          ],
        ),
      },
    ),

    SectorTemplate(
      id: 'repair-maintenance',
      label: 'Repair & Maintenance Services',
      blurb: 'Inbound repairs tracked to return and payment',
      examples: 'Appliance repair · Vehicle / two-wheeler repair · Electronics · Machinery repair',
      homeModule: ModuleType.crm,
      customFieldLabels: ['Item / Asset No.', 'Make / Model'],
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Repair Job',
          milestones: [
            'Job Received',
            'Assessment',
            'Quotation',
            'Repair In Progress',
            'Returned',
            'Payment Collected',
          ],
        ),
      },
    ),

    SectorTemplate(
      id: 'it-support',
      label: 'IT Support & Computer Services',
      blurb: 'Support tickets and on-site fixes resolved to closure',
      examples: 'Computer / laptop repair · Network & WiFi · Managed IT support · Software support',
      homeModule: ModuleType.crm,
      customFieldLabels: ['System / Asset', 'Contract No.'],
      modules: {
        ModuleType.crm: SectorModule(
          itemName: 'Support Job',
          milestones: [
            'Ticket Logged',
            'Triaged',
            'Remote Fix',
            'On-site Visit',
            'Resolved',
            'Closed',
          ],
        ),
      },
    ),

    // ── SALES front door: an enquiry/order moving through a won/lost funnel ──
    SectorTemplate(
      id: 'distributors-wholesale',
      label: 'Distributors & Wholesalers',
      blurb: 'Enquiry, quotation, order and collection pipeline',
      examples: 'FMCG distribution · Wholesale trading · B2B supply · Stockists',
      homeModule: ModuleType.sales,
      customFieldLabels: ['Product Line', 'Territory / Route'],
      modules: {
        ModuleType.sales: SectorModule(itemName: 'Order'),
        ModuleType.crm: SectorModule(itemName: 'Complaint'),
      },
    ),

    SectorTemplate(
      id: 'building-material',
      label: 'Building Material Dealers / Suppliers',
      blurb: 'Material enquiries, quotations and delivery collections',
      examples: 'Cement / steel · Sanitary & tiles · Paint & hardware · Aggregates',
      homeModule: ModuleType.sales,
      customFieldLabels: ['Site / Delivery', 'Order / PO No.'],
      modules: {
        ModuleType.sales: SectorModule(itemName: 'Material Order'),
        ModuleType.crm: SectorModule(itemName: 'Complaint'),
      },
    ),

    // ── WORKTRACKER front door: flat matter / work with a deadline ──
    SectorTemplate(
      id: 'ca-accounting-tax',
      label: 'CA / Accounting / Tax Firms',
      blurb: 'Client work and statutory filings tracked to filing',
      examples: 'CA / tax practice · GST / TDS returns · Bookkeeping · Audit',
      homeModule: ModuleType.task,
      customFieldLabels: ['Client / Entity', 'Year / Period'],
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Client Work',
          enableMilestones: true,
          milestones: [
            'Details / Documents Pending',
            'In Progress',
            'Review',
            'Filed',
            'Closed',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Engagement'),
      },
    ),

    SectorTemplate(
      id: 'interior-fitout',
      label: 'Interior & Fit-out Contractors',
      blurb: 'Site work moving from design to handover',
      examples: 'Interior design · Modular kitchen · Office fit-out · Renovation',
      homeModule: ModuleType.task,
      customFieldLabels: ['Site / Flat No.', 'Phase'],
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Project',
          enableMilestones: true,
          milestones: [
            'Design Approval',
            'Materials Procured',
            'Civil / Demolition',
            'Installation',
            'Finishing',
            'Handover',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Project'),
      },
    ),

    SectorTemplate(
      id: 'construction-civil',
      label: 'Construction / Civil Contractors',
      blurb: 'Site execution tracked stage by stage to handover',
      examples: 'Builders · Civil contractors · Roadwork · Structural work',
      homeModule: ModuleType.task,
      customFieldLabels: ['Site / Project', 'Phase / Stage'],
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Work',
          enableMilestones: true,
          milestones: [
            'Survey / Planning',
            'Excavation',
            'Foundation',
            'Structural',
            'Finishing',
            'Handover',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Project'),
      },
    ),

    SectorTemplate(
      id: 'marketing-agency',
      label: 'Marketing / Creative / Digital Agencies',
      blurb: 'Client deliverables moving from brief to go-live',
      examples: 'Ad agency · Digital / social media · Branding · Content studio',
      homeModule: ModuleType.task,
      customFieldLabels: ['Brand / Client', 'Campaign'],
      modules: {
        ModuleType.task: SectorModule(
          itemName: 'Campaign',
          enableMilestones: true,
          milestones: [
            'Brief',
            'Concept',
            'Creation',
            'Review',
            'Approval',
            'Go Live',
          ],
        ),
        ModuleType.sales: SectorModule(itemName: 'Brief'),
      },
    ),
  ];

  static SectorTemplate? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Sectors offered as choices in the pickers. Retired broad archetypes stay
  /// in [all] (so a saved id keeps resolving) but drop out of this view.
  static List<SectorTemplate> get pickable =>
      all.where((s) => s.pickerVisible).toList();

  /// The picker list grouped by each sector's front-door module, in display
  /// order: the neutral "General" default first, then the Service (CRM), Sales
  /// and Project/Task families. Empty families are omitted.
  static List<SectorGroup> get pickerGroups {
    final groups = <SectorGroup>[];
    final general = pickable.where((s) => s.id == 'general').toList();
    if (general.isNotEmpty) {
      groups.add(
        SectorGroup(
          title: 'Just getting started',
          subtitle: 'Generic tracking — change this anytime',
          sectors: general,
        ),
      );
    }
    void family(ModuleType home, String title, String subtitle) {
      final sectors = pickable
          .where((s) => s.id != 'general' && s.homeModule == home)
          .toList();
      if (sectors.isNotEmpty) {
        groups.add(
          SectorGroup(title: title, subtitle: subtitle, sectors: sectors),
        );
      }
    }

    family(
      ModuleType.crm,
      'Service & Repairs',
      'Jobs and tickets completed on-site or by support',
    );
    family(
      ModuleType.sales,
      'Sales & Orders',
      'Enquiries, quotes and orders to a won deal',
    );
    family(
      ModuleType.task,
      'Projects & Daily Work',
      'Tasks, matters and deliverables with deadlines',
    );
    return groups;
  }
}

/// Loads the app-wide "business type" once at startup into an in-memory cache
/// so synchronous UI rendering (card labels, AppBar titles, config getters) can
/// resolve the active vocabulary without awaiting SharedPreferences — the same
/// pattern [MilestoneSettingsService] uses for its enable flag.
class BusinessVocabulary {
  BusinessVocabulary._();

  static const String _key = 'business_type';

  /// SharedPreferences key holding the sector's front-door module
  /// ('sales'|'crm'|'task'). HomeScreen uses it as the fallback landing
  /// module when no explicit `last_home_module` has been recorded yet.
  static const String _homeKey = 'preferred_home_module';

  /// Number of user-defined custom-field slots on each item (shared with the
  /// detail-header chips and the Settings → Custom fields dialog).
  static const int kCustomFieldSlots = 3;

  /// SharedPreferences key recording which custom-field label slots a sector
  /// seeded, so switching sectors / returning to General can undo exactly
  /// those without touching labels the user named themselves.
  static const String _cfSeededKey = 'custom_field_seeded_slots';

  /// The label pref key for a 1-based custom-field slot.
  static String _customFieldLabelKey(int slot) => 'customFieldLabel$slot';

  static SectorTemplate? _current;
  static bool _loaded = false;

  /// The active sector template, or null when no business type is chosen
  /// ("general" behaves identically to no selection).
  static SectorTemplate? get current => _current;

  static bool get isLoaded => _loaded;

  /// Populate the in-memory cache from prefs. Call once during app startup,
  /// before the first frame renders.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _current = SectorTemplates.byId(prefs.getString(_key));
    _loaded = true;
  }

  /// Persist the chosen business type (empty / 'general' clears it) and update
  /// the in-memory cache. Also re-seeds the milestone templates for every
  /// module the sector defines. Returns the affected module types so callers
  /// can refresh just those screens.
  static Future<List<ModuleType>> set(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final sector = SectorTemplates.byId(id);
    // Record the front-door module. This is only a FIRST-TIME landing seed:
    // the standing rule is "reopen the last module the user actually opened"
    // (last_home_module), so we deliberately do NOT touch it here — changing
    // the business type later must not yank a returning user off their module.
    await prefs.setString(_homeKey, homePrefValue(sector));
    if (sector == null || sector.id == 'general') {
      await prefs.remove(_key);
      _current = null;
      // Phase-2E: switching back to General must restore generic defaults.
      // Drop any milestone templates/flags a prior sector seeded so a
      // returning "General" user gets the built-in pipelines again. Affects
      // only NEW items — existing cards keep their milestones.
      await resetMilestonesToDefaults();
      // Same reversibility for sector-seeded custom-field labels.
      await clearSeededCustomFieldLabels();
      return const [];
    }
    await prefs.setString(_key, sector.id);
    _current = sector;
    await seedCustomFieldLabels(sector);
    return seedMilestones(sector);
  }

  /// The `last_home_module`-compatible value for a sector's front door.
  /// Null (general / unset) resolves to the WorkTracker 'task' home.
  static String homePrefValue(SectorTemplate? sector) =>
      switch (sector?.homeModule ?? ModuleType.task) {
        ModuleType.sales => 'sales',
        ModuleType.crm => 'crm',
        ModuleType.task => 'task',
      };

  /// The persisted business-type id ('general' when none is set).
  static Future<String> savedId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? 'general';
  }

  /// Write the sector's milestone templates into each module it defines, and
  /// enable milestones where the sector needs them (Task milestones are
  /// opt-in). Only affects NEW cards — existing items keep their milestones.
  static Future<List<ModuleType>> seedMilestones(SectorTemplate sector) async {
    final affected = <ModuleType>[];
    for (final entry in sector.modules.entries) {
      final type = entry.key;
      final mod = entry.value;
      if (mod.milestones == null && !mod.enableMilestones) continue;
      final settings = MilestoneSettingsService(module: _moduleKey(type));
      if (mod.enableMilestones) {
        await settings.setEnabled(true);
      }
      if (mod.milestones != null) {
        await settings.saveTemplates(
          mod.milestones!
              .map(
                (t) => MilestoneTemplate(title: t, deadlineOffsetDays: null),
              )
              .toList(),
        );
      }
      affected.add(type);
    }
    return affected;
  }

  /// Phase-2E: restore every module's built-in milestone templates and default
  /// enable flag. Called when the business type is cleared back to "General"
  /// so a sector seed never outlives the sector. Only affects NEW items.
  static Future<void> resetMilestonesToDefaults() async {
    for (final module in const ['task', 'sales', 'crm']) {
      await MilestoneSettingsService(module: module).resetToDefaults();
    }
  }

  /// Phase-2E: seed the sector's default custom-field labels (slots 1..3) into
  /// any EMPTY slots, after clearing the labels a previously-chosen sector
  /// seeded. A label the user typed in Settings is never overwritten, and
  /// values already typed on items are untouched — this only names the fields.
  static Future<void> seedCustomFieldLabels(SectorTemplate sector) async {
    await clearSeededCustomFieldLabels();
    final prefs = await SharedPreferences.getInstance();
    final labels = sector.customFieldLabels;
    final seeded = <String>[];
    for (int i = 0; i < labels.length && i < kCustomFieldSlots; i++) {
      final label = labels[i].trim();
      if (label.isEmpty) continue;
      final key = _customFieldLabelKey(i + 1);
      // Skip a slot the user has already named themselves.
      if ((prefs.getString(key) ?? '').trim().isNotEmpty) continue;
      await prefs.setString(key, label);
      seeded.add('${i + 1}');
    }
    if (seeded.isNotEmpty) {
      await prefs.setStringList(_cfSeededKey, seeded);
    }
  }

  /// Remove the custom-field labels a sector seeded (slots recorded under
  /// [_cfSeededKey]) — used when switching sectors and on reset to General.
  static Future<void> clearSeededCustomFieldLabels() async {
    final prefs = await SharedPreferences.getInstance();
    final seeded = prefs.getStringList(_cfSeededKey) ?? const [];
    for (final slot in seeded) {
      final n = int.tryParse(slot);
      if (n != null) await prefs.remove(_customFieldLabelKey(n));
    }
    await prefs.remove(_cfSeededKey);
  }

  /// The MilestoneSettingsService module key for a [ModuleType]. Sales and CRM
  /// share the sales screens but keep separate template keys.
  static String _moduleKey(ModuleType type) => switch (type) {
    ModuleType.task => 'task',
    ModuleType.crm => 'crm',
    ModuleType.sales => 'sales',
  };

  // ── Synchronous lookups used by ModuleConfig getters ──────────────────────

  static String? itemNameFor(ModuleType type) =>
      _current?.moduleFor(type)?.itemName;

  static String? displayNameFor(ModuleType type) =>
      _current?.moduleFor(type)?.displayName;

  /// The Task module's item noun, sector-aware ("Task" / "Job" / "Activity" /
  /// "Deliverable"). WorkTracker screens hard-code their wording, so they read
  /// this instead of going through a [ModuleConfig] getter.
  static String get taskItemName => itemNameFor(ModuleType.task) ?? 'Task';

  /// Plural of [taskItemName] using the same rule the Sales/CRM home uses
  /// ("Tasks" / "Jobs" / "Activities" / "Deliverables").
  static String pluralTaskItemName() {
    final n = taskItemName;
    return n.endsWith('y') ? '${n.substring(0, n.length - 1)}ies' : '${n}s';
  }
}
