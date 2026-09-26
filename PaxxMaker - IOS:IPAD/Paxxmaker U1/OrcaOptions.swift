import Foundation

// MARK: - OrcaSlicer's own option names
//
// Generated from OrcaSlicer 2.4.2 (src/libslic3r/PrintConfig.cpp) and the
// translations that ship inside OrcaSlicer.app (i18n/<lang>/OrcaSlicer.mo), so
// a setting added in the slice-screen editor is called exactly what the
// program on the computer calls it — in the app's language.
//
// Two tables, both plain text so they cost nothing to compile: the options
// themselves, and one line per English string with its translations.

enum OrcaOptions {
    struct Def {
        let key: String
        let type: String            // coFloat, coInt, coBool, coPercent, coEnum …
        let label: String           // English
        let category: String        // English, "" when Orca gives none
        let unit: String            // sidetext, e.g. "mm/s"
        let min: Double?
        let max: Double?
        let values: [String]        // enum values as Orca spells them
        let valueLabels: [String]   // English labels for those values
    }

    static func def(_ key: String) -> Def? { table[key] }

    /// The string in the app's language; English when Orca has no translation.
    static func tr(_ english: String) -> String {
        guard !english.isEmpty else { return english }
        let lang = UserDefaults.standard.string(forKey: "orca_language") == "en"
            ? "en" : (UserDefaults.standard.string(forKey: "app_language") ?? "en")
        guard lang != "en", let i = ["de": 0, "fr": 1, "es": 2, "pt": 3, "it": 4, "zh": 5][lang],
              let row = translations[english], i < row.count, !row[i].isEmpty else { return english }
        return row[i]
    }

    /// Orca's name for a setting, already translated.
    static func title(_ key: String) -> String? { def(key).map { tr($0.label) } }

    private static let table: [String: Def] = {
        var out: [String: Def] = [:]
        for line in rawOptions.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 9 else { continue }
            out[f[0]] = Def(key: f[0], type: f[1], label: f[2], category: f[3], unit: f[4],
                            min: Double(f[5]), max: Double(f[6]),
                            values: f[7].isEmpty ? [] : f[7].components(separatedBy: ","),
                            valueLabels: f[8].isEmpty ? [] : f[8].components(separatedBy: "\u{a6}"))
        }
        return out
    }()

    private static let translations: [String: [String]] = {
        var out: [String: [String]] = [:]
        for line in rawTranslations.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2 else { continue }
            out[f[0]] = Array(f.dropFirst())
        }
        return out
    }()

    private static let rawOptions = #"""
accel_to_decel_enable	coBool	Enable accel_to_decel	Speed					
accel_to_decel_factor	coPercent	accel_to_decel	Speed		1	100		
adaptive_bed_mesh_margin	coFloat	Mesh margin		mm				
adaptive_layer_height	coBool	Adaptive layer height	Quality					
align_infill_direction_to_model	coBool	Align infill direction to model	Strength					
allow_multicolor_oneplate	coBool	Allow multiple colors on one plate						
allow_newer_file	coBool	Allow 3MF with newer version to be sliced						
allow_rotations	coBool	Allow rotation when arranging						
alternate_extra_wall	coBool	Alternate extra wall	Strength					
arrange	coInt	Arrange Options						
assemble	coBool	Assemble						
autosave	coString	Autosave						
auxiliary_fan	coBool	Auxiliary part cooling fan						
avoid_extrusion_cali_region	coBool	Avoid extrusion calibrate region when arranging						
bbl_calib_mark_logo	coBool	Show auto-calibration marks						
bbl_use_printhost	coBool	Use 3rd-party print host						
bed_custom_model	coString	Bed custom model						
bed_custom_texture	coString	Bed custom texture						
bed_temperature_formula	coEnum	Bed temperature type					by_first_filament,by_highest_temp	By First filament¦By Highest Temp
before_layer_change_gcode	coString	Before layer change G-code						
bottom_shell_layers	coInt	Bottom shell layers	Strength	layers	0			
bottom_shell_thickness	coFloat	Bottom shell thickness	Strength	mm	0			
bottom_solid_infill_flow_ratio	coFloat	Bottom surface flow ratio	Advanced		0	2		
bottom_surface_density	coPercent	Bottom surface density	Strength	%	10	100		
bottom_surface_filament_id	coInt	Bottom surface	Extruders		0			
bottom_surface_pattern	coEnum	Bottom surface pattern	Strength					
bridge_acceleration	coFloatOrPercent	Bridge	Speed	mm/s² or %	0			
bridge_angle	coFloat	External bridge infill direction	Strength		0	180		
bridge_density	coPercent	External bridge density	Strength		10	125		
bridge_flow	coFloat	Bridge flow ratio	Quality		0	2.0		
bridge_line_width	coFloatOrPercent	Bridge	Quality	mm or %	0	100		
bridge_no_support	coBool	Don't support bridges	Support					
bridge_speed	coFloat	External	Speed	mm/s	1			
brim_ears	coBool	Brim ears	Support					
brim_ears_detection_length	coFloat	Brim ear detection radius	Support	mm	0			
brim_ears_max_angle	coFloat	Brim ear max angle	Support		0	180		
brim_flow_ratio	coFloat	Brim flow ratio	Support		0	2		
brim_object_gap	coFloat	Brim-object gap	Support	mm	0	2		
brim_type	coEnum	Brim type	Support					
brim_use_efc_outline	coBool	Brim follows compensated outline	Support					
brim_width	coFloat	Brim width	Support	mm	0	100		
change_extrusion_role_gcode	coString	Change extrusion role G-code						
change_filament_gcode	coString	Change filament G-code						
combine_brims	coBool	Combine brims	Support					
compatible_printers_condition	coString	Condition						
compatible_prints_condition	coString	Condition						
config_compatibility	coEnum	Forward-compatibility rule when loading configurations from config files and project files (3MF, AMF).					disable,enable,enable_silent	Bail out on unknown configuration values¦Enable reading unknown configuration values by verbosely substituting them with defaults.¦Enable reading unknown configuration values by silently substituting them with defaults.
convert_unit	coBool	Convert Unit						
cooling_tube_length	coFloat	Cooling tube length		mm	0			
cooling_tube_retraction	coFloat	Cooling tube position		mm	0			
copy	coInt	Copy			1			
counterbore_hole_bridging	coEnum	Bridge counterbore holes	Quality					
curr_bed_type	coEnum	Bed type						
current_extruder	coInt	Current extruder						
current_object_idx	coInt	Current object index						
cut	coFloat	Cut						
cut_grid	coFloat	Cut						
cut_x	coFloat	Cut						
cut_y	coFloat	Cut						
datadir	coString	Data directory						
day	coInt	Day						
debug	coInt	Debug level			0			
default_acceleration	coFloat	Normal printing	Speed		0			
default_bed_type	coString	Default bed type						
default_jerk	coFloat	Default	Speed	mm/s	0			
default_junction_deviation	coFloat	Junction Deviation	Speed	mm	0.	0.3		
default_print_profile	coString	Default process profile						
detect_narrow_internal_solid_infill	coBool	Detect narrow internal solid infills	Strength					
detect_overhang_wall	coBool	Detect overhang walls	Quality					
detect_thin_wall	coBool	Detect thin walls	Strength					
disable_m73	coBool	Disable set remaining print time						
dont_filter_internal_bridges	coEnum	Filter out small internal bridges	Quality				disabled,limited,nofilter	Filter¦Limited filtering¦No filtering
downward_check	coBool	Downward machines check						
draft_shield	coEnum	Draft shield					disabled,enabled	Disabled¦Enabled
elefant_foot_compensation	coFloat	Elephant foot compensation	Quality	mm	0			
elefant_foot_compensation_layers	coInt	Elephant foot compensation layers	Quality	layers	1			
elefant_foot_layers_density	coPercent	Elephant foot layers density	Quality		50	100		
emit_machine_limits_to_gcode	coBool	Emit limits to G-code	Machine limits					
enable_arc_fitting	coBool	Arc fitting						
enable_extra_bridge_layer	coEnum	Extra bridge layers (beta)	Quality				disabled,external_bridge_only,internal_bridge_only,apply_to_all	Disabled¦External bridge only¦Internal bridge only¦Apply to all
enable_filament_dynamic_map	coBool	Enable filament dynamic map						
enable_filament_ramming	coBool	Enable filament ramming						
enable_overhang_speed	coBool	Slow down for overhang	Speed					
enable_power_loss_recovery	coEnum	Power Loss Recovery					printer_configuration,enable,disable	Printer configuration¦Enable¦Disable
enable_prime_tower	coBool	Enable						
enable_support	coBool	Enable support	Support					
enable_timelapse	coBool	Enable timelapse for print						
enable_tower_interface_cooldown_during_tower	coBool	Cool down from interface boost during prime tower						
enable_tower_interface_features	coBool	Enable tower interface features						
enable_wrapping_detection	coBool	Enable clumping detection						
enforce_support_layers	coInt	Enforce support for the first	Support	layers	0	5000		
ensure_on_bed	coBool	Ensure on bed						
ensure_vertical_shell_thickness	coEnum	Ensure vertical shell thickness	Strength				none,ensure_critical_only,ensure_moderate,ensure_all	None¦Critical Only¦Moderate¦All
exclude_object	coBool	Exclude objects						
export_3mf	coString	Export 3MF						
export_amf	coBool	Export AMF						
export_gcode	coBool	Export G-code						
export_obj	coBool	Export OBJ						
export_settings	coString	Export Settings						
export_sla	coBool	Export SLA						
export_slicedata	coString	Export slicing data						
export_stl	coBool	Export STL						
export_stls	coString	Export multiple STLs						
export_svg	coBool	Export SVG						
extra_loading_move	coFloat	Extra loading distance		mm				
extra_perimeters_on_overhangs	coBool	Extra perimeters on overhangs	Quality					
extra_solid_infills	coString	Insert solid layers	Strength					
extruded_volume_total	coFloat	Total volume						
extruded_weight_total	coFloat	Total weight						
extruder	coInt	Extruder	Extruders		0			
extruder_clearance_height_to_lid	coFloat	Height to lid		mm	0			
extruder_clearance_height_to_rod	coFloat	Height to rod		mm	0			
extruder_clearance_radius	coFloat	Radius		mm	0			
extrusion_rate_smoothing_external_perimeter_only	coBool	Apply only on external features						
fan_kickstart	coFloat	Fan kick-start time		s	0			
fan_speedup_overhangs	coBool	Only overhangs						
fan_speedup_time	coFloat	Fan speed-up time		s				
filament_extruder_id	coInt	Filament extruder ID						
filament_preset	coString	Filament preset name						
file_start_gcode	coString	File header G-code						
filename_format	coString	Filename format						
fill_multiline	coInt	Fill Multiline	Strength		1	10		
filter_out_gap_fill	coFloat	Filter out tiny gaps	Layers and Perimeters	mm				
first_layer_flow_ratio	coFloat	First layer flow ratio	Advanced		0	2		
first_layer_sequence_choice	coEnum	First layer filament sequence	Quality				Auto,Customize	Auto¦Customize
flashforge_serial_number	coString	Serial Number						
flush_into_infill	coBool	Flush into objects' infill	Flush options					
flush_into_objects	coBool	Flush into this object	Flush options					
flush_into_support	coBool	Flush into objects' support	Flush options					
fuzzy_skin	coEnum	Fuzzy Skin	Others				none,external,hole,all,allwalls,disabled_fuzzy	Painted only¦Contour¦Hole¦Contour and hole¦All walls¦Disabled
fuzzy_skin_first_layer	coBool	Apply fuzzy skin to first layer	Others					
fuzzy_skin_layers_between_ripple_offset	coInt	Layers between ripple offset	Others		1			
fuzzy_skin_mode	coEnum	Fuzzy skin generator mode	Others				displacement,extrusion,combined	Displacement¦Extrusion¦Combined
fuzzy_skin_noise_type	coEnum	Fuzzy skin noise type	Others				classic,perlin,billow,ridgedmulti,voronoi,ripple	Classic¦Perlin¦Billow¦Ridged Multifractal¦Voronoi¦Ripple
fuzzy_skin_octaves	coInt	Fuzzy Skin Noise Octaves	Others		1	10		
fuzzy_skin_persistence	coFloat	Fuzzy skin noise persistence	Others		0.01	1		
fuzzy_skin_point_distance	coFloat	Fuzzy skin point distance	Others	mm	0.01	5.		
fuzzy_skin_ripple_offset	coPercent	Ripple offset	Others	%	0	100		
fuzzy_skin_ripples_per_layer	coInt	Number of ripples per layer	Others		1			
fuzzy_skin_scale	coFloat	Fuzzy skin feature size	Others	mm	0.1	500		
fuzzy_skin_thickness	coFloat	Fuzzy skin thickness	Others	mm	0	2		
gap_fill_flow_ratio	coFloat	Gap fill flow ratio	Advanced		0	2		
gap_fill_target	coEnum	Apply gap fill	Strength				everywhere,topbottom,nowhere	Everywhere¦Top and bottom surfaces¦Nowhere
gap_infill_speed	coFloat	Gap infill	Speed	mm/s	1			
gcode_add_line_number	coBool	Add line number						
gcode_comments	coBool	Verbose G-code						
gcode_flavor	coEnum	G-code flavor					marlin,klipper,reprapfirmware,repetier,marlin2,reprap,teacup,makerware,sailfish,mach3,machinekit,smoothie,no-extrusion	marlin¦klipper¦reprapfirmware¦repetier¦marlin2¦reprap¦teacup¦makerware¦sailfish¦mach3¦machinekit¦smoothie¦no-extrusion
gcode_label_objects	coBool	Label objects						
gcodeviewer	coBool	G-code viewer						
gyroid_optimized	coBool	Z-buckling bias optimization (experimental)	Strength					
has_filament_switcher	coBool	Has filament switcher						
has_single_extruder_multi_material_priming	coBool	Has single extruder MM priming						
has_wipe_tower	coBool	Has wipe tower						
help	coBool	Help						
help_fff	coBool	Help (FFF options)						
help_sla	coBool	Help (SLA options)						
high_current_on_filament_swap	coBool	High extruder current on filament swap						
hole_to_polyhole	coBool	Convert holes to polyholes	Quality					
hole_to_polyhole_threshold	coFloatOrPercent	Polyhole detection margin	Quality	mm or %				
hole_to_polyhole_twisted	coBool	Polyhole twist	Quality					
host_type	coEnum	Host Type					prusalink,prusaconnect,octoprint,duet,flashair,astrobox,repetier,mks,esp3d,crealityprint,obico,flashforge,simplyprint,elegoolink,3dprinteros,moonraker	prusalink¦prusaconnect¦octoprint¦duet¦flashair¦astrobox¦repetier¦mks¦esp3d¦crealityprint¦obico¦flashforge¦simplyprint¦elegoolink¦3dprinteros¦moonraker
hour	coInt	Hour						
ignore_nonexistent_config	coBool	Ignore non-existent config files						
independent_support_layer_height	coBool	Independent support layer height	Support					
infill_anchor	coFloatOrPercent	Sparse infill anchor length	Strength	mm or %			0,1,2,5,10,1000	0¦1¦2¦5¦10¦1000
infill_anchor_max	coFloatOrPercent	Maximum length of the infill anchor	Strength					
infill_combination	coBool	Infill combination	Strength					
infill_combination_max_layer_height	coFloatOrPercent	Infill combination - Max layer height	Strength	mm or %	0			
infill_direction	coFloat	Sparse infill direction	Strength		0	360		
infill_jerk	coFloat	Infill	Speed	mm/s	0			
infill_lock_depth	coFloat	Infill lock depth	Strength	mm	0	100		
infill_overhang_angle	coFloat	Infill overhang angle	Strength		15	75		
infill_shift_step	coFloat	Infill shift step	Strength	mm	0	10		
infill_wall_overlap	coPercent	Infill/Wall overlap	Strength					
info	coBool	Output Model Info						
inherits	coString	Inherits profile						
initial_extruder	coInt	Initial extruder						
initial_filament_type	coString	Initial filament type						
initial_layer_acceleration	coFloat	First layer	Speed		0			
initial_layer_infill_speed	coFloat	First layer infill		mm/s	1			
initial_layer_jerk	coFloat	First layer	Speed	mm/s	0			
initial_layer_line_width	coFloatOrPercent	First layer	Quality	mm or %	0	1000		
initial_layer_min_bead_width	coPercent	First layer minimum wall width	Quality		0			
initial_layer_print_height	coFloat	First layer height	Quality	mm	0			
initial_layer_speed	coFloat	First layer		mm/s	1			
initial_layer_travel_acceleration	coFloatOrPercent	First layer travel		mm/s² or %	0			
initial_layer_travel_jerk	coFloatOrPercent	First layer travel		mm/s or %	0			
initial_layer_travel_speed	coFloatOrPercent	First layer travel speed	Speed	mm/s or %	1			
initial_tool	coInt	Initial tool						
inner_wall_acceleration	coFloat	Inner wall	Speed		0			
inner_wall_filament_id	coInt	Inner walls	Extruders		0			
inner_wall_flow_ratio	coFloat	Inner wall flow ratio	Advanced		0	2		
inner_wall_jerk	coFloat	Inner wall	Speed	mm/s	0			
inner_wall_line_width	coFloatOrPercent	Inner wall	Quality	mm or %	0	1000		
inner_wall_speed	coFloat	Inner wall	Speed	mm/s	1			
input_filename_base	coString	Input filename without extension						
input_shaping_damp_x	coFloat	X			0	1		
input_shaping_damp_y	coFloat	Y			0	1		
input_shaping_emit	coBool	Emit input shaping						
input_shaping_freq_x	coFloat	X			0	1000		
input_shaping_freq_y	coFloat	Y			0	1000		
input_shaping_type	coEnum	Input shaper type						
interface_shells	coBool	Interface shells	Quality					
interlocking_beam	coBool	Use beam interlocking	Advanced					
interlocking_beam_layer_count	coInt	Interlocking beam layers	Advanced		1			
interlocking_beam_width	coFloat	Interlocking beam width	Advanced	mm	0.01			
interlocking_boundary_avoidance	coInt	Interlocking boundary avoidance	Advanced		0			
interlocking_depth	coInt	Interlocking depth	Advanced		1			
interlocking_orientation	coFloat	Interlocking direction	Advanced		0	360		
internal_bridge_angle	coFloat	Internal bridge infill direction	Strength		0	180		
internal_bridge_density	coPercent	Internal bridge density	Strength		10	125		
internal_bridge_flow	coFloat	Internal bridge flow ratio	Quality		0	2.0		
internal_bridge_speed	coFloatOrPercent	Internal	Speed	mm/s or %	1			
internal_solid_filament_id	coInt	Internal solid infill	Extruders		0			
internal_solid_infill_acceleration	coFloatOrPercent	Internal solid infill	Speed	mm/s² or %	0			
internal_solid_infill_flow_ratio	coFloat	Internal solid infill flow ratio	Advanced		0	2		
internal_solid_infill_line_width	coFloatOrPercent	Internal solid infill	Quality	mm or %	0	1000		
internal_solid_infill_pattern	coEnum	Internal solid infill pattern	Strength					
internal_solid_infill_speed	coFloat	Internal solid infill	Speed	mm/s	1			
ironing_angle	coFloat	Ironing angle offset	Quality		0	359		
ironing_angle_fixed	coBool	Fixed ironing angle	Quality					
ironing_expansion	coFloat	Ironing expansion	Quality	mm	-100	100		
ironing_flow	coPercent	Ironing flow	Quality		0	100		
ironing_inset	coFloat	Ironing inset	Quality	mm	0	100		
ironing_pattern	coEnum	Ironing Pattern	Quality				rectilinear,concentric	Rectilinear¦Concentric
ironing_spacing	coFloat	Ironing line spacing	Quality	mm	0	1		
ironing_speed	coFloat	Ironing speed	Quality	mm/s	1			
ironing_type	coEnum	Ironing Type	Quality				no ironing,top,topmost,solid	No ironing¦Top surfaces¦Topmost surface¦All solid layers
is_infill_first	coBool	Print infill first	Quality					
lateral_lattice_angle_1	coFloat	Lateral lattice angle 1	Strength		-75	75		
lateral_lattice_angle_2	coFloat	Lateral lattice angle 2	Strength		-75	75		
layer_change_gcode	coString	Layer change G-code						
layer_height	coFloat	Layer height	Quality	mm	0			
layer_num	coInt	Layer number						
layer_z	coFloat	Layer Z						
lightning_overhang_angle	coFloat	Lightning overhang angle	Strength		5	85		
lightning_prune_angle	coFloat	Prune angle	Strength		5	85		
lightning_straightening_angle	coFloat	Straightening angle	Strength		5	85		
line_width	coFloatOrPercent	Default	Quality	mm or %	0	1000		
load_assemble_list	coString	Load assemble list						
load_custom_gcodes	coString	Load custom G-code						
load_defaultfila	coBool	Load default filaments						
logfile	coInt	Log file						
machine_end_gcode	coString	End G-code						
machine_load_filament_time	coFloat	Filament load time		s	0			
machine_pause_gcode	coString	Pause G-code						
machine_start_gcode	coString	Start G-code						
machine_tool_change_time	coFloat	Tool change time		s	0			
machine_unload_filament_time	coFloat	Filament unload time		s	0			
make_overhang_printable	coBool	Make overhangs printable	Quality					
make_overhang_printable_angle	coFloat	Make overhangs printable - Maximum angle	Quality		0.	90.		
make_overhang_printable_hole_size	coFloat	Make overhangs printable - Hole area	Quality		0.			
makerlab_name	coString	MakerLab name						
makerlab_version	coString	MakerLab version						
manual_filament_change	coBool	Manual Filament Change						
max_bridge_length	coFloat	Max bridge length	Support	mm	0			
max_layer_z	coFloat	Maximal layer Z						
max_resonance_avoidance_speed	coFloat	Max		mm/s	0			
max_travel_detour_distance	coFloatOrPercent	Avoid crossing walls - Max detour length	Quality	mm or %	0			
max_volumetric_extrusion_rate_slope	coFloat	Extrusion rate smoothing			0			
max_volumetric_extrusion_rate_slope_segment_length	coFloat	Smoothing segment length		mm	0.5	5		
min_bead_width	coPercent	Minimum wall width	Quality		0			
min_feature_size	coPercent	Minimum feature size	Quality		0			
min_length_factor	coFloat	Minimum wall length	Quality	mm	0.0	25.0		
min_resonance_avoidance_speed	coFloat	Min		mm/s	0			
min_save	coBool	Minimum save						
min_skirt_length	coFloat	Skirt minimum extrusion length		mm	0			
min_width_top_surface	coFloatOrPercent	One wall threshold	Quality	mm or %	0			
minimum_sparse_infill_area	coFloat	Minimum sparse infill threshold	Strength		0			
minute	coInt	Minute						
mmu_segmented_region_interlocking_depth	coFloat	Interlocking depth of a segmented region	Advanced	mm	0			
mmu_segmented_region_max_width	coFloat	Maximum width of a segmented region	Advanced	mm	0			
month	coInt	Month						
mstpp	coInt	mstpp						
mtcpp	coInt	mtcpp						
no_check	coBool	No check						
normal_print_time	coString	Print time (normal mode)						
normative_check	coBool	Normative check						
notes	coString	Configuration notes						
nozzle_height	coFloat	Nozzle height		mm	0			
nozzle_hrc	coInt	Nozzle HRC		HRC	0	500		
num_extruders	coInt	Number of extruders						
num_instances	coInt	Number of instances						
num_objects	coInt	Number of objects						
num_printing_extruders	coInt	Number of printing extruders						
only_one_wall_first_layer	coBool	Only one wall on first layer	Quality					
only_one_wall_top	coBool	Only one wall on top surfaces	Quality					
ooze_prevention	coBool	Enable						
orient	coInt	Orient Options						
other_layers_print_sequence_nums	coInt	The number of other layers print sequence						
other_layers_sequence_choice	coEnum	Other layers filament sequence	Quality				Auto,Customize	Auto¦Customize
outer_wall_acceleration	coFloat	Outer wall	Speed		0			
outer_wall_filament_id	coInt	Outer walls	Extruders		0			
outer_wall_flow_ratio	coFloat	Outer wall flow ratio	Advanced		0	2		
outer_wall_jerk	coFloat	Outer wall	Speed	mm/s	0			
outer_wall_line_width	coFloatOrPercent	Outer wall	Quality	mm or %	0	1000		
outer_wall_speed	coFloat	Outer wall	Speed	mm/s	1			
output	coString	Output File						
outputdir	coString	Output directory						
overhang_flow_ratio	coFloat	Overhang flow ratio	Advanced		0	2		
overhang_reverse	coBool	Reverse on even	Quality					
overhang_reverse_internal_only	coBool	Reverse only internal perimeters	Quality					
overhang_reverse_threshold	coFloatOrPercent	Reverse threshold	Quality	mm or %	0			
parallel_printheads_count	coInt	Parallel printheads count			1	4		
parking_pos_retraction	coFloat	Filament parking position		mm	0			
part_cooling_fan_min_pwm	coInt	Minimum non-zero part cooling fan speed		%	0	100		
pellet_modded_printer	coBool	Pellet Modded Printer						
physical_printer_preset	coString	Physical printer name						
pipe	coString	Send progress to pipe						
precise_outer_wall	coBool	Precise wall	Quality					
precise_z_height	coBool	Precise Z height	Quality					
preferred_orientation	coFloat	Preferred orientation			-360	360		
preheat_steps	coInt	Preheat steps			1	10		
preheat_time	coFloat	Preheat time		s	0	120		
prime_tower_brim_width	coFloat	Brim width		mm	-1		-1	Auto
prime_tower_enable_framework	coBool	Internal ribs						
prime_tower_infill_gap	coPercent	Infill gap			100			
prime_tower_skip_points	coBool	Skip points						
prime_tower_width	coFloat	Width		mm	2.0			
prime_volume	coFloat	Prime volume			1.0			
print_flow_ratio	coFloat	Flow ratio	Quality		0.01	2.		
print_host	coString	Hostname, IP or URL						
print_host_webui	coString	Device UI						
print_order	coEnum	Intra-layer order					default,as_obj_list	Default¦As object list
print_preset	coString	Print preset name						
print_sequence	coEnum	Print sequence					by layer,by object	By layer¦By object
print_time	coString	Print time (normal mode)						
print_time_sec	coString	Print time (seconds)						
printable_height	coFloat	Printable height		mm	0	214700		
printer_agent	coString	Printer Agent						
printer_model	coString	Printer type						
printer_notes	coString	Printer notes						
printer_preset	coString	Printer preset name						
printer_structure	coEnum	Printer structure					undefine,corexy,i3,hbot,delta	Undefine¦CoreXY¦I3¦Hbot¦Delta
printer_technology	coEnum	Printer technology					FFF,SLA	FFF¦SLA
printer_variant	coString	Printer variant						
printhost_apikey	coString	API Key / Password						
printhost_authorization_type	coEnum	Authorization Type					key,user	API key¦HTTP digest
printhost_cafile	coString	HTTPS CA File						
printhost_password	coString	Password						
printhost_port	coString	Printer						
printhost_ssl_ignore_revoke	coBool	Ignore HTTPS certificate revocation checks						
printhost_user	coString	User						
printing_by_object_gcode	coString	Between Object G-code						
printing_filament_types	coString	Used filament types						
process_change_extrusion_role_gcode	coString	Change extrusion role G-code (process)						
purge_in_prime_tower	coBool	Purge in prime tower						
raft_contact_distance	coFloat	Raft contact Z distance	Support	mm	0			
raft_expansion	coFloat	Raft expansion	Support	mm	0			
raft_first_layer_density	coPercent	First layer density	Support		10	100		
raft_first_layer_expansion	coFloat	First layer expansion	Support	mm	0			
raft_layers	coInt	Raft layers	Support	layers	0	100		
reduce_crossing_wall	coBool	Avoid crossing walls	Quality					
reduce_infill_retraction	coBool	Reduce infill retraction						
relative_bridge_angle	coBool	Relative bridge angle	Strength					
repair	coBool	Repair						
repetitions	coInt	Repetition count						
resolution	coFloat	Resolution		mm	0			
resonance_avoidance	coBool	Resonance avoidance						
role_based_wipe_speed	coBool	Role base wipe speed	Speed					
rotate	coFloat	Rotate						
rotate_x	coFloat	Rotate around X						
rotate_y	coFloat	Rotate around Y						
scale	coFloat	Scale						
scan_first_layer	coBool	Scan first layer						
scarf_angle_threshold	coInt	Conditional angle threshold	Quality		0	180		
scarf_joint_flow_ratio	coFloat	Scarf joint flow ratio	Quality		0	2		
scarf_joint_speed	coFloatOrPercent	Scarf joint speed	Quality	mm/s or %	1			
scarf_overhang_threshold	coPercent	Conditional overhang threshold	Quality		0			
seam_gap	coFloatOrPercent	Seam gap	Quality	mm or %	0			
seam_position	coEnum	Seam position	Quality				nearest,aligned,aligned_back,back,random	Nearest¦Aligned¦Aligned back¦Back¦Random
seam_slope_conditional	coBool	Conditional scarf joint	Quality					
seam_slope_entire_loop	coBool	Scarf around entire wall	Quality					
seam_slope_inner_walls	coBool	Scarf joint for inner walls	Quality					
seam_slope_min_length	coFloat	Scarf length	Quality	mm	0			
seam_slope_start_height	coFloatOrPercent	Scarf start height	Quality	mm or %	0			
seam_slope_steps	coInt	Scarf steps	Quality		1			
seam_slope_type	coEnum	Scarf joint seam (beta)	Quality				none,external,all	None¦Contour¦Contour and hole
second	coInt	Second						
set_other_flow_ratios	coBool	Set other flow ratios	Advanced					
silent_mode	coBool	Supports silent mode						
silent_print_time	coString	Print time (silent mode)						
single_extruder_multi_material	coBool	Single Extruder Multi Material						
single_extruder_multi_material_priming	coBool	Prime all printing extruders						
single_instance	coBool	Single instance mode						
single_loop_draft_shield	coBool	Single loop after first layer						
skeleton_infill_density	coPercent	Skeleton infill density	Strength		0	100		
skeleton_infill_line_width	coFloatOrPercent	Skeleton line width	Strength	mm	0			
skin_infill_density	coPercent	Skin infill density	Strength		0	100		
skin_infill_depth	coFloat	Skin infill depth	Strength	mm	0	100		
skin_infill_line_width	coFloatOrPercent	Skin line width	Strength	mm	0			
skip_modified_gcodes	coBool	Skip modified G-code in 3MF						
skirt_distance	coFloat	Skirt distance		mm	0	60		
skirt_height	coInt	Skirt height		layers		10000		
skirt_loops	coInt	Skirt loops			0	10		
skirt_speed	coFloat	Skirt speed		mm/s	0			
skirt_start_angle	coFloat	Skirt start point	Support		-180	180		
skirt_type	coEnum	Skirt type					combined,perobject	Combined¦Per object
slice	coInt	Slice						
slice_closing_radius	coFloat	Slice gap closing radius	Quality	mm	0			
slicing_mode	coEnum	Slicing Mode	Other				regular,even_odd,close_holes	Regular¦Even-odd¦Close holes
slow_down_layers	coInt	Number of slow layers	Speed	layers	0			
slowdown_for_curled_perimeters	coBool	Slow down for curled perimeters	Speed					
small_area_infill_flow_compensation	coBool	Small area flow compensation (beta)	Quality					
small_perimeter_speed	coFloatOrPercent	Small perimeters	Speed	mm/s or %	1			
small_perimeter_threshold	coFloat	Small perimeters threshold	Speed	mm	0			
solid_infill_direction	coFloat	Solid infill direction	Strength		0	360		
solid_infill_rotate_template	coString	Solid infill rotation template	Strength					
spaghetti_detector	coBool	Enable spaghetti detector						
sparse_infill_acceleration	coFloatOrPercent	Sparse infill	Speed	mm/s² or %	0			
sparse_infill_density	coPercent	Sparse infill density	Strength		0	100		
sparse_infill_filament_id	coInt	Infill	Extruders		0			
sparse_infill_flow_ratio	coFloat	Sparse infill flow ratio	Advanced		0	2		
sparse_infill_line_width	coFloatOrPercent	Sparse infill	Quality	mm or %	0	1000		
sparse_infill_pattern	coEnum	Sparse infill pattern	Strength				rectilinear,alignedrectilinear,zigzag,crosszag,lockedzag,line,grid,triangles,tri-hexagon,cubic,adaptivecubic,quartercubic,supportcubic,lightning,honeycomb,3dhoneycomb,lateral-honeycomb,lateral-lattice,crosshatch,tpmsd,tpmsfk,gyroid,concentric,hilbertcurve,archimedeanchords,octagramspiral	Rectilinear¦Aligned Rectilinear¦Zig Zag¦Cross Zag¦Locked Zag¦Line¦Grid¦Triangles¦Tri-hexagon¦Cubic¦Adaptive Cubic¦Quarter Cubic¦Support Cubic¦Lightning¦Honeycomb¦3D Honeycomb¦Lateral Honeycomb¦Lateral Lattice¦Cross Hatch¦TPMS-D¦TPMS-FK¦Gyroid¦Concentric¦Hilbert Curve¦Archimedean Chords¦Octagram Spiral
sparse_infill_rotate_template	coString	Sparse infill rotation template	Strength					
sparse_infill_speed	coFloat	Sparse infill	Speed	mm/s	1			
spiral_finishing_flow_ratio	coFloat	Spiral finishing flow ratio			0	1		
spiral_mode	coBool	Spiral vase						
spiral_mode_max_xy_smoothing	coFloatOrPercent	Max XY Smoothing		mm or %	0	1000		
spiral_mode_smooth	coBool	Smooth Spiral						
spiral_starting_flow_ratio	coFloat	Spiral starting flow ratio			0	1		
split	coBool	Split						
staggered_inner_seams	coBool	Staggered inner seams	Quality					
standby_temperature_delta	coInt	Temperature variation			-			
support_air_filtration	coBool	Support air filtration						
support_angle	coFloat	Pattern angle	Support		0	359		
support_base_pattern	coEnum	Base pattern	Support				default,rectilinear,rectilinear-grid,honeycomb,lightning,hollow	Default¦Rectilinear¦Rectilinear grid¦Honeycomb¦Lightning¦Hollow
support_base_pattern_spacing	coFloat	Base pattern spacing	Support	mm	0			
support_bottom_interface_spacing	coFloat	Bottom interface spacing	Support	mm	0			
support_bottom_z_distance	coFloat	Bottom Z distance	Support	mm	0			
support_chamber_temp_control	coBool	Support control chamber temperature						
support_critical_regions_only	coBool	Support critical regions only	Support					
support_expansion	coFloat	Normal Support expansion	Support	mm				
support_filament	coInt	Support/raft base	Support		0			
support_flow_ratio	coFloat	Support flow ratio	Advanced		0	2		
support_interface_bottom_layers	coInt	Bottom interface layers	Support	layers	-1		-1	Same as top
support_interface_filament	coInt	Support/raft interface	Support		0			
support_interface_flow_ratio	coFloat	Support interface flow ratio	Advanced		0	2		
support_interface_loop_pattern	coBool	Interface use loop pattern	Support					
support_interface_not_for_body	coBool	Avoid interface filament for base	Support					
support_interface_pattern	coEnum	Interface pattern	Support				auto,rectilinear,concentric,rectilinear_interlaced,grid	Default¦Rectilinear¦Concentric¦Rectilinear Interlaced¦Grid
support_interface_spacing	coFloat	Top interface spacing	Support	mm	0			
support_interface_speed	coFloat	Support interface	Speed	mm/s	1			
support_interface_top_layers	coInt	Top interface layers	Support	layers	0		0,1,2,3	0¦1¦2¦3
support_ironing	coBool	Ironing Support Interface	Support					
support_ironing_flow	coPercent	Support Ironing flow	Support		0	100		
support_ironing_pattern	coEnum	Support Ironing Pattern	Support				rectilinear,concentric	Rectilinear¦Concentric
support_ironing_spacing	coFloat	Support Ironing line spacing	Support	mm	0	1		
support_line_width	coFloatOrPercent	Support	Quality	mm or %	0	1000		
support_multi_bed_types	coBool	Support multi bed types						
support_object_first_layer_gap	coFloat	Support/object first layer gap	Support	mm	0	10		
support_object_xy_distance	coFloat	Support/object XY distance	Support	mm	0	10		
support_on_build_plate_only	coBool	On build plate only	Support					
support_parallel_printheads	coBool	Support parallel printheads						
support_remove_small_overhang	coBool	Ignore small overhangs	Support					
support_speed	coFloat	Support	Speed	mm/s	1			
support_style	coEnum	Style	Support				default,grid,snug,organic,tree_slim,tree_strong,tree_hybrid	Default (Grid/Organic)¦Grid¦Snug¦Organic¦Tree Slim¦Tree Strong¦Tree Hybrid
support_threshold_angle	coInt	Threshold angle	Support		0	90		
support_threshold_overlap	coFloatOrPercent	Threshold overlap	Support	mm or %	0	100		
support_top_z_distance	coFloat	Top Z distance	Support	mm	0		0,0.1,0.2	0 (soluble)¦0.1 (semi-detachable)¦0.2 (detachable)
support_type	coEnum	Type	Support				normal(auto),tree(auto),normal(manual),tree(manual)	Normal (auto)¦Tree (auto)¦Normal (manual)¦Tree (manual)
sw_renderer	coBool	Render with a software renderer			0			
symmetric_infill_y_axis	coBool	Symmetric infill Y axis	Strength					
template_custom_gcode	coString	Custom G-code						
thick_bridges	coBool	Thick external bridges	Quality					
thick_internal_bridges	coBool	Thick internal bridges	Quality					
thumbnails	coString	G-code thumbnails						
thumbnails_format	coEnum	Format of G-code thumbnails					PNG,JPG,QOI,BTT_TFT,COLPIC	PNG¦JPG¦QOI¦BTT_TFT¦COLPIC
time_cost	coFloat	Time cost		money/h	0			
time_lapse_gcode	coString	Timelapse G-code						
timelapse_type	coEnum	Timelapse						
timestamp	coString	Timestamp						
tool_change_on_wipe_tower	coBool	Tool change on wipe tower						
top_bottom_infill_wall_overlap	coPercent	Top/Bottom solid infill/wall overlap	Strength					
top_shell_layers	coInt	Top shell layers	Strength	layers	0			
top_shell_thickness	coFloat	Top shell thickness	Strength	mm	0			
top_solid_infill_flow_ratio	coFloat	Top surface flow ratio	Advanced		0	2		
top_surface_acceleration	coFloat	Top surface	Speed		0			
top_surface_density	coPercent	Top surface density	Strength	%	0	100		
top_surface_filament_id	coInt	Top surface	Extruders		0			
top_surface_jerk	coFloat	Top surface	Speed	mm/s	0			
top_surface_line_width	coFloatOrPercent	Top surface	Quality	mm or %	0	1000		
top_surface_pattern	coEnum	Top surface pattern	Strength				monotonic,monotonicline,rectilinear,alignedrectilinear,concentric,hilbertcurve,archimedeanchords,octagramspiral	Monotonic¦Monotonic line¦Rectilinear¦Aligned Rectilinear¦Concentric¦Hilbert Curve¦Archimedean Chords¦Octagram Spiral
top_surface_speed	coFloat	Top surface	Speed	mm/s	1			
total_cost	coFloat	Total cost						
total_layer_count	coInt	Total layer count						
total_toolchanges	coInt	Total tool changes						
total_weight	coFloat	Total weight						
total_wipe_tower_cost	coFloat	Total wipe tower cost						
total_wipe_tower_filament	coFloat	Wipe tower volume						
travel_acceleration	coFloat	Travel	Speed		0			
travel_jerk	coFloat	Travel	Speed	mm/s	0			
travel_speed	coFloat	Travel		mm/s	1			
travel_speed_z	coFloat	Z travel		mm/s	0			
tree_support_angle_slow	coFloat	Preferred Branch Angle	Support		10	85		
tree_support_auto_brim	coBool	Auto brim width	Quality					
tree_support_branch_angle	coFloat	Tree support branch angle	Support		0	60		
tree_support_branch_angle_organic	coFloat	Tree support branch angle	Support		0	60		
tree_support_branch_diameter	coFloat	Tree support branch diameter	Support	mm	1.0	10		
tree_support_branch_diameter_angle	coFloat	Branch Diameter Angle	Support		0	15		
tree_support_branch_diameter_organic	coFloat	Tree support branch diameter	Support	mm	1.0	10		
tree_support_branch_distance	coFloat	Tree support branch distance	Support	mm	1.0	10		
tree_support_branch_distance_organic	coFloat	Tree support branch distance	Support	mm	1.0	10		
tree_support_brim_width	coFloat	Tree support brim width	Quality		0.0			
tree_support_tip_diameter	coFloat	Tip Diameter	Support	mm	0.1	100.		
tree_support_top_rate	coPercent	Branch Density	Support		5			
tree_support_wall_count	coInt	Support wall loops	Support		0	2		
tree_support_with_infill	coBool	Tree support with infill	Support					
uptodate	coBool	UpToDate						
use_3mf	coBool	Use 3MF instead of G-code						
use_firmware_retraction	coBool	Use firmware retraction						
use_relative_e_distances	coBool	Use relative E distances						
used_filament	coFloat	Used filament						
used_filament_length	coString	Filament length (meters)						
wall_direction	coEnum	Wall loop direction	Quality				ccw,cw	Counter clockwise¦Clockwise
wall_distribution_count	coInt	Wall distribution count	Quality		1			
wall_generator	coEnum	Wall generator	Quality				classic,arachne	Classic¦Arachne
wall_loops	coInt	Wall loops	Strength		0	1000		
wall_maximum_deviation	coFloat	Maximum wall deviation	Quality	mm	0.005	0.05		
wall_maximum_resolution	coFloat	Maximum wall resolution	Quality	mm	0.005	0.5		
wall_sequence	coEnum	Walls printing order	Quality				inner wall/outer wall,outer wall/inner wall,inner-outer-inner wall	Inner/Outer¦Outer/Inner¦Inner/Outer/Inner
wall_transition_angle	coFloat	Wall transitioning threshold angle	Quality		1.	59.		
wall_transition_filter_deviation	coPercent	Wall transitioning filter margin	Quality		0			
wall_transition_length	coPercent	Wall transition length	Quality		0			
wipe_before_external_loop	coBool	Wipe before external loop	Quality					
wipe_on_loops	coBool	Wipe on loops	Quality					
wipe_speed	coFloatOrPercent	Wipe speed	Speed	mm/s or %	0			
wipe_tower_bridging	coFloat	Maximal bridging distance		mm				
wipe_tower_cone_angle	coFloat	Stabilization cone apex angle			0.	90.		
wipe_tower_extra_flow	coPercent	Extra flow for purging			100.	300.		
wipe_tower_extra_rib_length	coFloat	Extra rib length		mm		300		
wipe_tower_extra_spacing	coPercent	Wipe tower purge lines spacing			100.	300.		
wipe_tower_filament	coInt	Wipe tower	Extruders		0			
wipe_tower_fillet_wall	coBool	Fillet wall						
wipe_tower_max_purge_speed	coFloat	Maximum wipe tower print speed		mm/s	10			
wipe_tower_no_sparse_layers	coBool	No sparse layers (beta)						
wipe_tower_rib_width	coFloat	Rib width		mm	0	300		
wipe_tower_rotation_angle	coFloat	Wipe tower rotation angle						
wipe_tower_type	coEnum	Wipe tower type						
wipe_tower_wall_type	coEnum	Wall type						
wrapping_detection_gcode	coString	Clumping detection G-code						
wrapping_detection_layers	coInt	Clumping detection layers			0			
xy_contour_compensation	coFloat	X-Y contour compensation	Quality	mm				
xy_hole_compensation	coFloat	X-Y hole compensation	Quality	mm				
year	coInt	Year						
z_offset	coFloat	Z offset		mm				
zaa_dont_alternate_fill_direction	coBool	Don't alternate fill direction	Quality					
zaa_enabled	coBool	Z contouring enabled	Quality					
zaa_min_z	coFloat	Minimum Z height	Quality	mm	0	100		
zaa_minimize_perimeter_height	coFloat	Minimize wall height angle	Quality		0	90		
zhop	coFloat	Current Z-hop						
"""#

    private static let rawTranslations = #"""
3D Honeycomb	3D-Waben	Nid d'abeille 3D	Panal 3D	Favo de Mel 3D	Nido d'ape 3D	3D 蜂窝
API Key / Password	API-Schlüssel / Passwort	Clé API / Mot de passe	Clave API / Contraseña	Chave da API / Senha	Chiave API / Password	API秘钥/密码
API key	API-Schlüssel	Clé API	Clave API	API Key	Chiave API	API秘钥
Adaptive Cubic	Adaptiv kubisch	Cubique adaptatif	Cúbico Adaptativo	Cúbico Adaptativo	Cubico adattivo	自适应立方体
Add line number	Liniennummer hinzufügen	Ajouter un numéro de ligne	Añadir número de línea	Adicionar número da linha	Aggiungi numero di riga	标注行号
Advanced	Erweiterte Einstellungen	Avancé	Avanzado	Avançado	Avanzate	高级
Align infill direction to model	Füllrichtung am Modell ausrichten	Aligner la direction du remplissage sur le modèle	Alinear la dirección de relleno al modelo	Alinhar direção do preenchimento ao modelo	Allinea direzione riempimento al modello	对齐填充方向到模型
Aligned	Ausgerichtet	Alignée	Alineado	Alinhada	Allineato	对齐
Aligned Rectilinear	Geradlinig ausgerichtet	Rectiligne Aligné	Rectilíneo Alineado	Retilíneo alinhado	Rettilineo allineato	直线排列
Aligned back	Ausgerichtet hinten	Aligné à l'arrière	Alineado atrás	Alinhada atrás	Allineato dietro	背部对齐
All	Alle	Tous	Todas	Todos	Tutto	所有
All solid layers		Toutes les couches pleines	Todas las capas sólidas	Todas as camadas sólidas	Tutti gli strati solidi	所有实心层
All walls	Alle Wände	Toutes les parois	Todas los perímetros	Todas as paredes	Tutte le pareti	所有墙
Allow 3MF with newer version to be sliced	Erlauben Sie das Slicen von 3MF mit neuerer Version	Autoriser le tranchage des 3MF de version plus récente	Permitir laminar 3MF con versión más nueva	Permitir que 3MF com versão mais recente seja fatiado	Consenti l'elaborazione del file 3MF con la versione più recente	允许较新版本的 3MF 进行切片
Allow multiple colors on one plate	Erlaube mehrere Farben auf einer Platte	Permettre l’utilisation de plusieurs couleurs sur une même plaque	Permitir múltiples colores en una cama	Permitir várias cores em uma placa	Consenti più colori sul piatto	允许在一个打印板上使用多种颜色
Allow rotation when arranging	Erlaube Drehungen beim Anordnen	Autoriser des rotations dans le cadre d’un réagencement	Permitir rotación al organizar	Permitir rotações ao arranjar	Consenti rotazioni quando si dispone	排列时允许旋转
Alternate extra wall	Abwechselnde zusätzliche Wand	Paroi supplémentaire alternée	Perímetro adicional alternado	Parede extra alternada	Parete aggiuntiva alternativa	交替添加额外内墙
Apply fuzzy skin to first layer	Fuzzy Skin auf die erste Schicht anwenden	Appliquer la surface irrégulière sur la première couche	Aplicar superficie difusa en la primera capa	Aplicar textura difusa à primeira camada	Applica la superficie ruvida sul primo strato	绒毛表面应用至首层
Apply gap fill	Lückenfüllung anwenden	Remplissage des trous	Aplicar relleno de huecos	Aplicar preenchimento de vão	Applica riempimento spazi vuoti	启用间隙填充
Apply only on external features	Nur auf externe Funktionen anwenden	Ne s’applique qu’aux parties extérieures	Aplicar solo en características externas	Aplicar somente em recursos externos	Applica solo su elementi esterni	仅应用于外部特征
Apply to all	Auf alle anwenden	Appliquer à tous	Aplicar a todos	Aplicar a todos	Applica a tutti	全部应用
Arachne		Arachné				
Arc fitting	Als Bogen drucken	Tracer des arcs	Activar movimientos en arco	Ajuste de arco (Arc fitting)	Adattamento ad arco	圆弧拟合
Archimedean Chords	Archimedische Akkorde	Spirale d'Archimède	Espiral de Arquímedes	Cordas Arquimedeanas	Corde di Archimede	阿基米德和弦
Arrange Options	Anordnungsoptionen	Options d’agencement	Opciones de posicionamiento	Opções de Arranjo	Opzioni disposizione	摆放选项
As object list	Als Objektliste	En tant que liste d’objets	Como lista de objetos	Como lista de objetos	Come elenco di oggetti	按对象列表中的顺序
Assemble	Zusammenbauen	Assembler	Agrupar	Montar	Assembla	组合
Authorization Type	Autorisierungstyp	Type d'Autorisation	Tipo de autorización	Tipo de autorização	Tipo di autorizzazione	授权类型
Auto	Automatisch		Automático			自动
Auto brim width	Automatische Randbreite	Largeur de la bordure automatique	Ancho de borde de adherencia automático	Largura de borda automática	Larghezza tesa automatica	自动裙边宽度
Auxiliary part cooling fan	Hilfslüfter	Ventilateur de refroidissement auxiliaire	Ventilador auxiliar de refrigeración de piezas	Ventilador auxiliar de resfriamento de peças	Ventola di raffreddamento ausiliaria	辅助部件冷却风扇
Avoid crossing walls	Vermeiden von Wandüberquerungen	Évitez de traverser les parois	Evitar cruzar perímetro	Evitar atravessar paredes	Evita di attraversare le pareti	避免跨越外墙
Avoid crossing walls - Max detour length	Vermeide das Überqueren der Wand - Maximale Umleitungslänge	Évitez de traverser les parois - Longueur maximale du détour	Evitar cruzar perímetro - Longitud de desvío máximo	Evitar atravessar paredes - Distância máximo do desvio	Evitare di attraversare le pareti - Lunghezza massima della deviazione	避免跨越外墙-最大绕行长度
Avoid extrusion calibrate region when arranging	Vermeiden Sie den Extrusionskalibrierungsbereich beim Anordnen	Éviter la région d’étalonnage de l’extrusion lors de l’arrangement	Evitar región de calibración de extrusión al organizar	Evitar a região de calibração de extrusão ao arranjar	Evita regione calibrazione estrusione quando si dispone	排列时避开挤出校准区域
Avoid interface filament for base	Schnittstellenfilament für die Basis verringern	Réduire le filament d’interface pour la base	Evitar usar filamento de interfaz para la base	Evitar o filamento da interface para a base	Evita filamento interfaccia per base	界面材料不用于主体
Back	Zurück	Arrière	Trasera	Atrás	Posteriore	背面
Base pattern	Basismuster	Motif de base	Patrón de base	Padrão da base	Motivo base	支撑主体图案
Base pattern spacing	Abstand des Grundmusters	Espacement du motif de base	Espaciado del patrón base	Espaçamento do padrão de base	Spaziatura motivo base	主体图案线距
Bed custom model	Benutzerspezifisches Druckbettmodell	Modèle de plateau personnalisé	Modelo personalizado de cama	Modelo personalizado da mesa	Modello piano personalizzato	自定义热床模型
Bed custom texture	Benutzerdefinierte Textur des Druckbettes	Texture personnalisée du plateau	Textura personalizada de cama	Textura personalizada da mesa	Superficie piano personalizzata	自定义热床纹理
Bed temperature type	Betttemperaturtyp	Type de température du plateau	Tipo de temperatura de la cama	Tipo de temperatura de mesa	Tipo temperatura piatto	热床温度类型
Bed type	Druckbetttyp	Type de plaque	Tipo de cama	Tipo de placa	Tipo di piatto	热床类型
Before layer change G-code	G-Code vor dem Schichtwechsel	G-Code avant changement de couche	G-Code para antes del cambio de capa	G-code antes da mudança de camada	G-code prima del cambio strato	换层前G-code
Between Object G-code	Zwischen Objekt G-Code	G-code entre objet	G-Code ejecutado entre Objetos	G-code entre objetos	G-code tra oggetti	对象之间Gcode
Billow			Ondulado		Ondulato	云状噪波
Bottom Z distance	Unterer Z-Abstand	Distance Z inférieure	Distancia Z inferior	Distância Z inferior	Distanza Z inferiore	底部Z距离
Bottom interface layers	Untere Schnittstellenschichten	Couches d'interface inférieures	Capas de la interfaz inferior	Camadas de interface inferior	Strati interfaccia inferiore	底部接触面层数
Bottom interface spacing	Abstand der unteren Schnittstelle	Espacement de l'interface inférieure	Espaciado de la interfaz inferior	Espaçamento da interface inferior	Spaziatura interfaccia inferiore	底部接触面线距
Bottom shell layers	Untere Schalenschichten	Couches inférieures de la coque	Capas inferiores de cubierta	Camadas da casca de base	Strati guscio inferiore	底部壳体层数
Bottom shell thickness	Dicke der unteren Schale	Épaisseur de la coque inférieure	Espesor mínimo de la cubierta inferior	Espessura da casca de base	Spessore guscio inferiore	底部壳体厚度
Bottom surface	Untere Fläche	Surface inférieure	Relleno sólido inferior	Superfície inferior	Superficie inferiore	底面
Bottom surface density	Dichte der unteren Oberfläche	Densité de la surface inférieure	Densidad de la superficie inferior	Densidade da superfície inferior	Densità superficie inferiore	底面密度
Bottom surface flow ratio	Durchflussverhältnis untere Fläche	Ratio du débit des surfaces inférieures	Factor de flujo en superficie inferior	Taxa de fluxo em superfície inferior	Flusso di stampa superficie inferiore	底部表面流量比例
Bottom surface pattern	Muster der unteren Fläche	Motif de surface inférieure	Patrón de relleno de cubierta inferior	Padrão de superfície inferior	Motivo superficie inferiore	底面图案
Branch Density	Ast-Dichte	Densité des branches	Densidad de ramas	Densidade da ramificação	Densità Rami	分支密度
Branch Diameter Angle	Ast-Verjüngungs-Winkel	Angle du diamètre des branches	Ángulo del Diámetro de ramas	Ângulo do diâmetro da ramificação	Angolo diametro dei rami	分支直径的角度
Bridge	Überbrückung	Pont	Puente	Ponte	Ponte	桥接
Bridge counterbore holes	Brücken für Senkungen	Trous d'alésage pour le pont	Crear puentes en agujeros con avellanado	Pontes para furos rebaixados	Ponti fori svasati	沉孔搭桥
Bridge flow ratio	Brücken Flussrate	Débit des ponts	Factor de flujo en puentes	Taxa de fluxo em ponte	Flusso di stampa ponti	桥接流量
Brim ear detection radius	Radius für die Erkennung von Brim-Ohren	Rayon de détection de la bordure à oreilles	Radio de detección de Orejas de borde	Raio de detecção da orelha da borda	Raggio di rilevamento tesa ad orecchio	圆盘检测半径
Brim ear max angle	Maximaler Winkel für Brim-Ohren	Angle maximum de la bordure à oreilles	Ángulo máximo de las Orejas de borde	Ângulo máximo da orelha da borda	Angolo massimo della tesa ad orecchio	圆盘最大角度
Brim ears	Brim-Ohren	Bordure à oreilles	Orejas de borde	Orelhas da borda	Tesa ad orecchio	圆盘
Brim flow ratio	Brim-Flussverhältnis	Rapport de débit de la bordure	Factor de flujo del borde de adherencia	Taxa de fluxo em borda	Flusso di stampa tese	Brim流量比
Brim follows compensated outline	Umrandung folgt einem kompensierten Umriss	Bordure suit le contour compensé	Borde de adherencia sigue el esquema compensado	Borda segue contorno compensado	Tesa su contorno con compensazione	Brim遵循补偿轮廓
Brim type	Randtyp	Type de bordure	Tipo de borde de adherencia	Tipo de borda	Tipo di tesa	Brim类型
Brim width	Randbreite	Largeur de la bordure	Ancho del borde de adherencia	Largura da borda	Larghezza tesa	Brim宽度
Brim-object gap	Lücke zwischen Rand und Objekt	Écart bord-objet	Espaciado borde de adherencia-objeto	Espaço entre a borda e objeto	Spazio tesa-oggetto	Brim与模型的间隙
By First filament	Nach dem ersten Filament	Par le premier filament	Por primer filamento	Por Primeiro Filamento	Per primo filamento	根据初始打印耗材
By Highest Temp	Nach der höchsten Temperatur	Par la température la plus élevée	Por temperatura máxima	Por Maior Temperatura	Per temperatura più alta	根据最高打印温度
By layer	Nach Ebene	Par couche	Por capa	Por camada	Per strato	逐层
By object	Nach Objekt	Par objet	Por objeto	Por objeto	Per oggetto	逐件
Change extrusion role G-code	Ändere den G-Code der Extrusionsart	G-code de changement du rôle de l’extrusion	G-Code de cambio de rol de extrusión	G-code de mudança de tipo de extrusão	G-code cambio ruolo di estrusione	挤出类型更换G-code
Change extrusion role G-code (process)	G-Code für den Wechsel der Extrusionsrolle (Prozess)	G-code de changement du rôle de l’extrusion (traitement)	G-Code de cambio de rol de extrusión (proceso)	G-code de mudança de tipo de extrusão (processo)	Modifica G-code ruolo di estrusione (processo)	挤出类型更换 G-code（工艺）
Change filament G-code	Filamentwechsel G-Code	G-code de changement de filament	G-Code para el cambio de filamento	G-code de mudança de filamento	G-code cambio filamento	耗材丝更换G-code
Classic	Klassisch	Classique	Clásico	Clássico	Classico	经典
Clockwise	Im Uhrzeigersinn	Dans le sens des aiguilles d’une montre	En el sentido de las agujas del reloj	Horário	Senso orario	顺时针
Close holes	Löcher schließen	Combler les trous	Cerrar orificios	Fechar buracos	Chiudi fori	闭孔
Clumping detection G-code	Klumpen-Erkennungs-G-Code	G-code de détection d'agglomération	G-code de detección de aglomeraciones	G-code para detecção de aglomeração	G-code rilevamento ammassi	结块检测 G-code
Clumping detection layers	Klumpen-Erkennungsschichten	Couches de détection d'agglomération	Capas de detección de aglomeraciones	Camadas de detecção de aglomeração	Strati di rilevamento ammassi	结块监测层数
Combine brims	Ränder kombinieren	Combiner les bordures	Combinar bordes de adherencia	Combinar bordas	Unisci tese	合并Brim
Combined	Kombiniert	Combiné	Combinado	Combinado	Combinata	合并
Concentric	Konzentrisch	Concentrique	Concéntrico	Concêntrico	Concentrico	同心
Condition	Bedingung		Condición	Condição	Condizione	条件
Conditional angle threshold	Winkel-Schwellenwert	Seuil d’angle conditionnel	Umbral angular para union de bufanda condicional	Limiar de ângulo condicional	Soglia angolo condizionale	角度阈值
Conditional overhang threshold	Bedingte Überstandsschwelle	Seuil de dépassement conditionnel	Umbral de voladizo para unión de bufanda condicional	Limiar de saliência condicional	Soglia di sporgenza condizionale	悬垂阈值
Conditional scarf joint	Bedingte Schrägnaht	Couture en biseau conditionnelle	Unión de bufanda condicional	Junta cachecol condicional	Cucitura a sciarpa condizionale	选择性应用斜拼接缝
Configuration notes	Konfigurationsnotizen	Notes de la configuration	Anotaciones de configuración	Notas de configuração	Note di configurazione	配置注释
Contour	Kontur		Contorno	Contorno	Contorno	轮廓
Contour and hole	Kontur und Loch	Contour et trou	Contorno y orificio	Contorno e furo	Contorno e foro	轮廓和孔
Convert Unit	Einheit umrechnen	Convertir l'unité	Convertir Unidad	Converter Unidades	Converti unità	转换单位
Convert holes to polyholes	Konvertiere Löcher zu Polyholes	Convertir les trous en trous polygones	Convertir orificios en poliorificios	Converter furos em polifuros	Converti fori in polifori	将圆孔转换为多边型孔
Cool down from interface boost during prime tower	Abkühlung von der Schnittstellen-Boost während des Reinigungsturms	Refroidissement depuis l'augmentation de température d'interface pendant la tour d'amorçage	Enfriamiento tras el aumento de temperatura de la interfaz durante la torre de purga	Resfriamento após aquecimento para interface durante a torre de preparo	Raffreddamento dall'aumento di interfaccia durante la torre di spurgo	擦拭塔期间从接触层加速状态冷却
Cooling tube length	Kühlrohrlänge	Longueur du tube de refroidissement	Longitud del tubo de refrigeración	Comprimento do tubo de resfriamento	Lunghezza tubo di raffreddamento	喉管长度
Cooling tube position	Position des Kühlrohrs	Position du tube de refroidissement	Posición del tubo de refrigeración	Posição do tubo de resfriamento	Posizione tubo di raffreddamento	喉管位置
Copy	Kopieren	Copier	Copiar	Copiar	Copia	复制
Counter clockwise	Gegen den Uhrzeigersinn	Sens inverse des aiguilles d’une montre	En sentido contrario a las agujas del reloj	Anti-horário	Senso antiorario	逆时针
Critical Only	Nur kritisch	Critique seulement	Sólo críticos	Apenas crítico	Solo Critico	仅关键区域
Cross Hatch	Kreuzschraffur	Quadrillage	Rayado Cruzado	Hachura Cruzada	Trama incrociata	交叉层叠
Cross Zag	Kreuz-Zick-Zack	Zig Zag croisé	Zag Cruzado	Zague Cruzado		交叉之字
Cubic	Kubisch	Cubique	Cúbico	Cúbico	Cubico	立方体
Current Z-hop	Aktuelles Z-Hop	Saut en z actuel	Z-Hop actual	Z-hop atual	Sollevamento Z corrente	当前 Z 轴抬升
Current extruder	Aktueller Extruder	Extrudeur actuel	Extrusora actual	Extrusora atual	Estrusore attuale	当前挤出机
Current object index	Aktueller Objektindex	Index de l’objet actuel	Índice del objeto actual	Índice do objeto atual	Indice dell'oggetto corrente	当前对象编号
Custom G-code	Benutzerdefinierter G-Code	G-code personnalisé	G-Code personalizado	G-code Personalizado	G-code personalizzato	自定义G-code
Customize	Anpassen	Personnaliser	Personalizar	Personalizar	Personalizza	自定义
Cut	Schneiden	Couper	Cortar	Cortar	Taglia	剪切
Data directory	Datenverzeichnis	Répertoire de données	Directorio de datos	Diretório de dados	Cartella dati	数据目录
Day	Tag	Jour	Día	Dia	Giorno	天
Debug level	Fehlersuchstufe	Niveau de débogage	Nivel de depuración	Nível de depuração	Livello di debug	调试等级
Default	Standard	Défaut	Por defecto	Padrão	Predefinito	默认
Default (Grid/Organic)	Standard (Gitter/Organisch)	Défaut (Grille/Organique)	Por defecto (Cuadrícula/Orgánico)	Padrão (Grade/Orgânico)	Predefinito (Griglia/Organico)	默认 (网格/有机)
Default bed type	Standard Druckbett-Typ	Type de plateau par défaut	Tipo de cama predeterminado	Tipo de placa padrão	Tipo di piatto predefinito	默认热床类型
Default process profile	Standard-Prozessprofil	Profil de traitement par défaut	Perfil de proceso por defecto	Perfil de processo padrão	Profilo di processo predefinito	默认切片配置
Delta						Delta（三角）
Detect narrow internal solid infills		Détecter les remplissages solides internes étroits	Detectar relleno sólido interno estrecho	Detectar preenchimentos sólidos internos estreitos	Rileva riempimento solido interno su piccole aree	识别狭窄的内部实心填充
Detect overhang walls		Détecter les parois en surplomb	Detectar perímetros en voladizo	Detectar paredes salientes	Rileva pareti sporgenti	识别悬垂外墙
Detect thin walls		Détecter les parois fines	Detección de perímetros delgados	Detectar paredes finas	Rileva pareti sottili	检查薄壁
Device UI	Gerät	Interface utilisateur de l’appareil	IU de dispositivo	Interface do dispositivo	Interfaccia utente del dispositivo	设备用户界面
Disable	Deaktivieren	Désactiver	Desactivar	Desativar	Disabilita	禁用
Disable set remaining print time	Deaktiviere die verbleibende Druckzeit	Désactiver le réglage du temps d’impression restant	Desactivar tiempo de impresión restante	Desabilitar definir tempo de impressão restante	Disabilita tempo di stampa rimanente impostato	禁用M73剩余打印时间
Disabled	Deaktiviert	Désactivé	Desactivado	Desativado	Disabilitato	禁用
Displacement	Verschiebung	Déplacement	Desplazamiento	Deslocamento	Spostamento	位移
Don't alternate fill direction	Füllrichtung nicht wechseln	Ne pas alterner le sens de remplissage	No alternar la dirección de relleno	Não alternar direção de preenchimento	Non alternare direzione riempimento	不交替填充方向
Don't support bridges	Brücken nicht unterstützen	Ne pas créer de supports sous les ponts	No soportar puentes	Não suportar pontes	Non supportare i ponti	不支撑桥接
Downward machines check	Abwärtz Kompatibilitätsprüfung	Vérification des machines en aval	Comprobación de compatibilidad descendente	Verificação descendente de máquinas	Controllo macchine compatibili verso il basso	向下兼容机器检查
Draft shield	Luftzug-Schutz	Paravent	Protector contra corrientes de aire	Escudo de ar	Scudo protettivo	风挡
Elephant foot compensation	Elefantenfußkompensation	Compensation de l'effet patte d'éléphant	Compensación de Pata de elefante	Compensação de pé de elefante	Compensazione zampa d'elefante	象脚补偿
Elephant foot compensation layers	Elefantenfußkompensationsschichten	Couches de compensation de la patte d'éléphant	Capas de compensación de Pata de elefante	Camadas de compensação de pé de elefante	Strati compensazione zampa d'elefante	象脚补偿层数
Elephant foot layers density	Dichte der Schichten für die Elefantenfußkompensation	Densité des couches de patte d’éléphant	Densidad de capas del pie de elefante	Densidade das camadas do pé de elefante	Densità strati zampa d'elefante	象脚补偿层密度
Emit input shaping	Input Shaping ausgeben	Émettre la mise en forme du signal	Emitir input shaping	Emitir modelagem de entrada	Sovrascrivi compensazione risonanza	输出输入整形
Emit limits to G-code	Werte im G-Code ausgeben	Émission des limites vers le G-code	Emitir límites al G-Code	Emitir limites para o G-code	Emetti limiti al G-code	写入限制到G-code
Enable	Aktivieren	Activer	Habilitar	Ativar	Abilita	开启
Enable accel_to_decel	Beschleunigung zu Verzögerung einschalten	Activer l’accélération à la décélération	Activar acel_a_decel	Habilitar accel_to_decel	Abilita accel_to_decel	启用制动速度
Enable clumping detection	Klumpen-Erkennung aktivieren	Activer la détection d'agglomération	Activar detección de aglomeraciones	Habilitar detecção de aglomeração	Abilita rilevamento ammassi	启用结块检测
Enable filament dynamic map	Dynamische Filamentzuordnung aktivieren	Activer le mappage dynamique des filaments	Habilitar mapa dinámico de filamentos	Habilitar mapa dinâmico de filamento		启用耗材动态映射
Enable filament ramming	Erlaube Filamentrammen	Activer le bourrage de filament	Habilitar compactación de filamento	Habilitar moldeamento de filamento	Abilita spinta del filamento	启用耗材尖端成型
Enable support	Stützstrukturen aktivieren	Activer les supports	Habilitar los soportes	Ativar suporte	Abilita supporti	开启支撑
Enable timelapse for print	Zeitraffer für Druck aktivieren	Activer le timelapse pour l’impression	Habilitar timelapse para impresión	Habilitar timelapse para impressão	Abilita timelapse per la stampa	为打印启用延时摄影
Enable tower interface features	Aktiviere Funktionen der Turmschnittstelle	Activer les fonctionnalités d'interface de la tour	Habilitar las funciones de la torre de interfaz	Ativar recursos da interface da torre	Abilita funzionalità interfaccia torre	启用擦拭塔接触层功能
Enabled	Aktiviert	Activé	Activado	Ativado	Abilitato	启用
End G-code	End G-Code	G-code de fin	G-Code final	G-code de finalização	G-code finale	结尾G-code
Ensure on bed	Auf dem Bett stellen	Assurer sur le plateau	Auto-ajustar a la cama	Garantir na mesa	Accerta che sia sul piano	确保在热床上
Ensure vertical shell thickness	Sicherstellung der vertikalen Wanddicke	Assurer l’épaisseur de la coque verticale	Garantizar el grosor vertical de las cubiertas	Garantir a espessura vertical da casca	Garantisci spessore verticale del guscio	确保垂直外壳厚度
Even-odd	Gerade-ungerade	Pair-impair	Par-impar	Par-impar	Pari-dispari	奇偶
Everywhere	Überall	Partout	En todas partes	Sempre	Ovunque	所有地方
Exclude objects	Objekte ausschließen	Exclure des objets	Excluir objetos	Excluir objetos	Escludi oggetti	对象排除
Export 3MF	3mf exportieren	Exporter 3MF	Exportar 3MF	Exportar 3MF	Esporta 3MF	导出 3MF
Export G-code	Exportiere G-Code	Exporter le G-code	Exportar G-Code	Exportar G-code	Esporta G-code	导出 G-code
Export STL	Exportiere STL	Exporter STL	Exportar STL	Exportar STL	Esporta STL	导出STL文件
Export Settings	Einstellungen exportieren	Paramètres d'exportation	Ajustes de exportación	Exportar Configurações	Esporta impostazioni	导出配置
Export multiple STLs	Mehrere STLs exportieren	Exporter plusieurs STL	Exportar múltiples STL	Exportar vários STLs	Esporta STL multipli	导出多个STL
Export slicing data	Slicing-Daten exportieren	Exporter les données de tranchage	Exportar datos de laminado	Exportar dados de fatiamento	Esporta dati elaborati	导出切片数据
External	Extern	Externe	Externo	Externo	Esterno	外部
External bridge density	Externe Brücken Dichte	Densité du pont externe	Densidad de puente externo	Densidade de ponte externa	Densità ponti esterni	外部桥接密度
External bridge infill direction	Externe Brücken Füllrichtung	Direction du remplissage du pont extérieur	Dirección de relleno de puentes externos	Direção de preenchimento de ponte externa	Angolo riempimento ponti esterni	外部桥接填充方向
External bridge only	Nur externe Brücke	Pont externe uniquement	Solo puente externo	Apenas pontes externas	Solo ponti esterni	仅外部桥接
Extra bridge layers (beta)	Zusätzliche Brückenschichten (Beta)	Couches de pont supplémentaires (beta)	Capas extra de puente (beta)	Camadas extras de ponte (beta)	Strati ponte aggiuntivi (beta)	额外桥层（测试版）
Extra flow for purging	Zusätzlicher Fluss für Reinigung	Débit supplémentaire pour purger	Caudal adicional para purgar	Fluxo extra para purga	Flusso aggiuntivo per spurgo	额外冲刷量
Extra loading distance	Zusätzliche Länge beim Laden	Distance de chargement supplémentaire	Distancia extra de carga	Distância de carregamento extra	Distanza di caricamento aggiuntiva	额外加载距离
Extra perimeters on overhangs	Extra Umfänge bei Überhängen	Parois supplémentaires sur les surplombs	Perímetros extra en voladizos	Paredes extras em saliências	Pareti aggiuntive su sporgenze	悬垂上的额外周长
Extra rib length	Extralänge der Rippe	Longueur supplémentaire de la nervure	Longitud extra del refuerzo	Comprimento extra de nervura	Lunghezza nervatura aggiuntiva	额外加强筋长度
Extruder		Extrudeur	Extrusor	Extrusora	Estrusore	挤出机
Extruders	Extruder	Extrudeurs	Extrusores	Extrusoras	Estrusori	挤出机
Extrusion			Extrusión	Extrusão	Estrusione	挤出
Extrusion rate smoothing	Glättung der Extrusionsrate	Lissage du taux d’extrusion	Suavizado de la tasa de extrusión	Suavização da extrusão	Livellamento velocità di estrusione	平滑挤出率
Fan kick-start time	Lüfter Anlaufzeit	Durée de démarrage du ventilateur	Tiempo de arranque de ventilador	Tempo de inicialização do ventilador	Tempo avvio ventola	风扇
Fan speed-up time	Lüfter Beschleunigungszeit	Durée d’accélération du ventilateur	Tiempo de aumento de velocidad del ventilador	Tempo de aceleração do ventilador	Tempo accelerazione ventola	风扇响应时间
Filament extruder ID	Extruder-ID des Filaments	ID de l’extrudeur de filaments	ID extrusor filamento	ID da extrusora de filamento	ID estrusore di filamento	耗材挤出机ID
Filament length (meters)	Filamentlänge (Meter)	Longueur de filament (mètres)	Longitud de filamento (metros)	Comprimento do filamento (metros)	Lunghezza filamento (metri)	耗材长度（米）
Filament load time	Ladedauer des Filaments	Temps de chargement du filament	Tiempo de carga de filamento	Tempo de carga do filamento	Durata caricamento filamento	装载耗材丝的时间
Filament parking position	Filament Parkposition	Position de stationnement du filament	Posición de parada de filamento	Posição de estacionamento do filamento	Posizione parcheggio del filamento	耗材停靠位置
Filament preset name	Name der Filamentprofile	Nom du préréglage du filament	Nombre del perfil de filamento	Nome da predefinição de filamento	Nome del profilo del filamento	耗材预设名称
Filament unload time	Entladezeit des Filaments	Temps de déchargement du filament	Tiempo de descarga del filamento	Tempo de descarga do filamento	Durata scaricamento filamento	卸载耗材丝的时间
File header G-code	Datei Header G-Code	G-code d'en-tête de fichier	G-Code de cabecera de archivo	G-code do cabeçalho do arquivo	G-code intestazione file	文件头 G-code
Filename format	Format des Dateinamens	Format du nom de fichier	Formato de los nombres de archivo	Formato do nome do arquivo	Formato nome file	文件名格式
Fill Multiline	Mehrzeilige Füllung	Remplissage multiligne	Relleno multilínea	Multilinhas de Preenchimento	Riempimento multilinea	填充多线
Fillet wall	Gefüllte Wand	Paroi avec congé	Pared con chaflán	Parede chanfrada	Parete con raccordo	墙加圆角
Filter		Filtrer	Filtro	Filtrar	Filtra	过滤
Filter out small internal bridges	Kleine interne Brücken filtern	Filtrer les petits ponts internes	Filtrar puentes internos pequeños	Filtrar pontes internas pequenas	Filtra piccoli ponti interni	过滤掉小的内部桥接
Filter out tiny gaps	Filtert winzige Lücken aus	Filtrer les petits espaces	Filtrar pequeños huecos	Filtrar vazios pequenos	Filtra piccoli spazi vuoti	忽略微小间隙
First layer	Erste Schicht	Couche initiale	Capa inicial	Primeira camada	Primo strato	首层
First layer density	Dichte der ersten Schicht	Densité de couche initiale	Densidad de la primera capa	Densidade da primeira camada	Densità primo strato	首层密度
First layer expansion	Ausdehnung der ersten Schicht	Extension de la couche initiale	Expansión de la primera capa	Expansão da primeira camada	Espansione primo strato	首层扩展
First layer filament sequence	Erste Filament-Schichtsequenz	Séquence d’impression de la première couche	Secuencia de primera capa de filamento	Sequência de filamento da primeira camada	Sequenza filamenti primo strato	首层耗材打印顺序
First layer flow ratio	Flussverhältnis der ersten Schicht	Ratio de débit de la première couche	Factor de flujo en primera capa	Fluxo na primeira camada	Flusso di stampa primo strato	第一层流量比
First layer height	Höhe der ersten Schicht	Hauteur de couche initiale	Altura de la primera capa	Altura da primeira camada	Altezza primo strato	首层层高
First layer infill	Füllung	Remplissage de la couche initiale	Relleno de la primera capa	Preenchimento da primeira camada	Riempimento primo strato	首层填充
First layer minimum wall width	Erste Schicht minimale Wandbreite	Largeur minimale de la paroi de la première couche	Ancho mínimo del perímetro de la primera capa	Largura mínima de parede da primeira camada	Larghezza minima parete del primo strato	首层最小墙宽度
First layer travel	Bewegung der ersten Schicht	Déplacement de la première couche	Recorrido de primera capa	Deslocamento para primeira camada	Spostamento primo strato	首层空驶
First layer travel speed	Geschwindigkeit der ersten Schicht	Déplacements	Velocidad de desplazamiento en la primera capa	Velocidade de deslocamento da primeira camada	Velocità spostamento primo strato	首层空驶速度
Fixed ironing angle	Fester Glättwinkel	Angle de lissage fixe	Ángulo de alisado fijo	Ângulo fixo para alisamento	Angolo di stiratura fisso	固定角度熨烫
Flow ratio	Flussverhältnis	Rapport de débit	Factor de flujo	Taxa de fluxo	Flusso di stampa	流量比例
Flush into objects' infill	Düse in der Füllung des Objekts reinigen	Purger dans le remplissage d'objet	Purgar en el relleno de objetos	Purgar no preenchimento dos objetos	Spurga nel riempimento dell'oggetto	冲刷到对象的填充
Flush into objects' support	Düse in der Stützstruktur des Objekts reinigen	Purger dans les supports de l'objet	Purgar en los soportes de objetos	Purgar nos suportes dos objetos	Spurga nei supporti dell'oggetto	冲刷到对象的支撑
Flush into this object	Düse in diesem Objekt reinigen	Purger dans cet objet	Purgar en este objeto	Purgar neste objeto	Spurga in questo oggetto	冲刷到这个对象
Flush options	Optionen für die Düsenreinigung	Options de purge	Opciones de purgado de filamento	Opções de purga	Opzioni spurgo	换料冲刷选项
Format of G-code thumbnails	Format der G-Code-Vorschaubilder	Format des vignettes G-code	Formato de las miniaturas de G-Code	Formato das miniaturas de G-code	Formato miniature G-code	G-code缩略图的格式
Fuzzy Skin		Surface Irrégulière	Superficie rugosa	Textura Difusa	Superficie ruvida	绒毛表面
Fuzzy Skin Noise Octaves	Fuzzy Skin Rauschoktaven	Octaves de bruits de surface irrégulière	Octavas de ruido de la piel difusa	Oitavas de ruído de textura difusa	Ottave rumore superficie ruvida	绒毛噪波倍频
Fuzzy skin feature size	Fuzzy Skin Merkmalsgröße	Taille des caractéristiques de la surface irrégulière	Tamaño de característica de la piel difusa	Tamanho dos elementos da textura difusa	Dimensione struttura superficie ruvida	绒毛表面特征尺寸
Fuzzy skin generator mode	Fuzzy Skin Generierungsmodus	Mode du générateur de surface irrégulière	Modo generador de piel difusa	Modo gerador de textura difusa	Modalità generatore superficie ruvida	绒毛表面生成器模式
Fuzzy skin noise persistence	Fuzzy Skin Rauschpersistenz	Persistance du bruit de la surface irrégulière	Persistencia del ruido de piel difusa	Persistência de ruído de textura difusa	Persistenza rumore superficie ruvida	绒毛噪波持续性
Fuzzy skin noise type	Fuzzy Skin Rauschtyp	Type de bruit de surface irrégulière	Tipo de ruido de la piel difusa	Tipo de ruído da textura difusa	Tipo di rumore superficie ruvida	绒毛噪波类型
Fuzzy skin point distance	Fuzzy Skin Punktabstand	Distance de point de la surface irrégulière	Distancia entre puntos de superficie rugosa	Distância do ponto da textura difusa	Distanza punti superficie ruvida	绒毛表面点间距
Fuzzy skin thickness	Fuzzy Skin Stärke	Épaisseur de la surface Irrégulière	Espesor de superficie rugosa	Espessura da textura difusa	Spessore superficie ruvida	绒毛表面厚度
G-code flavor	G-Code Typ	Version du G-code	Tipo de G-Code	Tipo de G-code	Formato G-code	G-code风格
G-code thumbnails	G-Code Vorschaubilder	Vignette G-code	Miniaturas de G-Code	Miniaturas de G-code	Miniature G-code	G-code缩略图尺寸
Gap fill flow ratio	Lückenfüllung Durchflußrate	Ratio de débit du remplissage des espaces	Factor de flujo para relleno de huecos	Taxa de fluxo em preenchimento de vãos	Flusso di stampa riempimento spazi	间隙填充流量比
Gap infill	Lückenfüllung	Remplissage d'espace	Relleno de huecos	Preenchimento de vão	Riempimento spazi vuoti	填缝
Grid	Gitternetz	Grille	Cuadrícula	Grade	Griglia	网格
Gyroid		Gyroïde	Giroide	Giroide	Giroide	螺旋体
HTTP digest	HTTP-Digest	Résumé HTTP	Resumen HTTP	Digest HTTP	Autenticazione sicura HTTP	HTTP摘要
HTTPS CA File	HTTPS CA-Datei	Fichier HTTPS CA	Archivo CA HTTPS	Arquivo CA HTTPS	File CA HTTPS	HTTPS CA文件
Has filament switcher	Hat Filamentwechsler	Dispose d’un commutateur de filament	Cuenta con un selector de filamentos	Tem trocador de filamentos		具有耗材切换器
Has single extruder MM priming	Hat einzelnes Extruder-MM-Priming	Dispose d’un seul extrudeur MM d’amorçage	Parámetros de cambio de cabezal para impresoras de 1 extrusor MM	Tem preparação de extrusora MM única	Ha spurgo estrusore singolo MM	单挤出机多材料预挤出
Has wipe tower	Hat Reinigungsturm	Possède une tour d’essuyage	Tiene torre de purga	Tem torre de limpeza	Ha una torre di spurgo	有擦拭塔
Height to lid	Höhe zum Deckel	Hauteur au couvercle	Altura hasta la tapa	Altura até a tampa	Altezza coperchio	到顶盖高度
Height to rod	Höhe zur Führung	Hauteur jusqu’à la tige	Altura a la barra	Altura até a haste	Altezza asta	到横杆高度
Help	Hilfe	Aide	Ayuda	Ajuda	Aiuto	帮助
High extruder current on filament swap	Hoher Extruderstrom beim Filamentwechsel	Courant de l’extrudeur élevé lors du changement de filament	Aumentar la corriente del motor de extrusión durante el cambio de filamento	Corrente da extrusora alta na troca de filamento	Aumenta corrente estrusore al cambio filamento	更换耗材挤出机大电流
Hilbert Curve	Hilbert-Kurve	Courbe de Hilbert	Curva de Hilbert	Curva de Hilbert	Curva di Hilbert	希尔伯特曲线
Hole	Loch	Trou	Orificio	Furo	Foro	孔
Hollow	Hohl	Creux	Hueco	Oco	Vuoto	空心
Honeycomb	Bienenwabe	Nid d'abeille	Panal	Favo de Mel	Nido d'ape	蜂窝
Host Type	Host-Typ	Type d'hôte	Tipo de host	Tipo de Host	Tipo di host	主机类型
Hostname, IP or URL	Hostname, IP oder URL	Nom d'hôte, adresse IP ou URL	Nombre de host, IP o URL	Nome do host, IP ou URL	Nome servizio, IP o URL	主机名，IP或者URL
Hour	Stunde	Heure	Hora	Hora	Ora	时
Ignore HTTPS certificate revocation checks	HTTPS-Zertifikatssperrprüfungen ignorieren	Ignorer les contrôles de révocation des certificats HTTPS	Ignorar comprobaciones de revocación de certificado HTTPS	Ignorar verificações de revogação de certificado HTTPS	Ignora i controlli di revoca dei certificati HTTPS	忽略HTTPS证书吊销检查
Ignore small overhangs	Kleine Überhänge ignorieren	Ignorer les petits surplombs	Ignorar pequeños voladizos	Ignorar pequenas saliências	Ignora piccole sporgenze	忽略微小悬垂
Independent support layer height	Unabhängige Stützstruktur-Schichthöhe	Hauteur de la couche de support indépendante	Altura independiente de la capa de soporte	Altura independente da camada de suporte	Altezza strato supporto indipendente	支撑独立层高
Infill	Füllung	Remplissage	Relleno	Preenchimento	Riempimento	填充
Infill combination	Kombinieren der Füllung	Combinaison de remplissage	Combinación de relleno	Combinar preenchimento	Combinazione riempimento	合并填充
Infill combination - Max layer height	Kombinieren der Füllung - Maximale Schichthöhe	Combinaison de remplissage - Hauteur maximale de la couche	Combinación de relleno - Altura máxima de la capa	Combinação de preenchimento - Altura máx da camada	Combinazione riempimento - Altezza massima strato	填充组合 - 最大层高
Infill gap	Infill-Lücke	Écart de remplissage	Rellenar hueco	Vão entre preenchimentos	Spazio del riempimento	填补空白
Infill lock depth	Sperrtiefe der Füllung	Profondeur de verrouillage du remplissage	Profundidad de agarre del relleno	Profundade de travamento do preenchimento	Profondità intersezione riempimento	填充锁定深度
Infill overhang angle	Überhangwinkel der Füllung	Angle de surplomb du remplissage	Ángulo de voladizo del relleno	Ângulo de saliência do preenchimento	Angolo di sbalzo del riempimento	填充悬垂角度
Infill shift step	Füllverschiebungsschritt	Pas de décalage du remplissage	Paso de desplazamiento de relleno	Passo de deslocamento de preenchimento	Passo di spostamento del riempimento	填充偏移步长
Infill/Wall overlap	Überlappung Füllung/Wand	Chevauchement de remplissage/paroi	Solape de relleno/perímetro	Sobreposição de preenchimento/parede	Sovrapposizione riempimento/parete	填充/墙 重叠
Inherits profile	Übernimmt Profil	Hérite du profil	Hereda el perfil	Herda o perfil	Eredita profilo	继承配置文件
Initial extruder	Erster Extruder	Extrudeur initial	Extrusor inicial	Extrusora inicial	Estrusore iniziale	初始挤出机
Initial tool	Erstes Werkzeug	Outil de départ	Herramienta inicial	Ferramenta inicial	Testina iniziale	初始工具
Inner wall	Innere Wand	Paroi intérieure	Perímetro interno	Parede interna	Parete interna	内墙
Inner wall flow ratio	Innenwand Durchflußrate	Ratio de débit de la paroi intérieure	Factor de flujo en perímetro interior	Taxa de fluxo em parede interna	Flusso di stampa pareti interne	内壁流量比
Inner walls	Innere Wände	Parois internes	Paredes internas	Paredes internas		内墙
Inner/Outer	Innen/Außen	Intérieur/Extérieur	Interior/Exterior	Interior/Exterior	Interna/Esterna	内墙/外墙
Inner/Outer/Inner	Innenwand/Außenwand/Innenwand	Intérieur/Extérieur/Intérieur	Interior/Exterior/Interior	Interior/Exterior/Interior	Interna/Esterna/Interna	内墙/外墙/内墙
Input filename without extension	Eingabedateiname ohne Erweiterung	Nom du fichier d’entrée sans extension	Nombre de archivo de entrada sin extensión	Nome do arquivo de entrada sem extensão	Nome del file di input senza estensione	输入文件名（无扩展名）
Input shaper type	Input Shaper Typ	Type de compensateur de résonance	Tipo de input shaper	Tipo de modelador de entrada	Tipo di compensazione della risonanza	输入整形器类型
Insert solid layers	Massive Schichten einfügen	Insérer des couches solides	Insertar capas sólidas	Inserir camadas sólidas	Inserisci strati solidi	插入实心层
Interface pattern	Schnittstellenmuster	Motif d'interface	Patrón de interfaz	Padrão de interface	Motivo interfaccia	支撑面图案
Interface shells	Support-Verbindung	Coque des interfaces	Perímetros de interfaz	Cascas de interface	Pareti interfaccia	接触面外壳
Interface use loop pattern	Schleifenmuster-Schnittstelle	Modèle de boucle d'utilisation d'interface	Uso de la interfaz en forma de bucle	Interface usa padrão de volta	Usa motivo ad anello per interfaccie	接触面采用圈形走线。
Interlocking beam layers	Interlock-Struktur Schichten	Couches de poutres emboîtées	Capas de vigas de entrelazado	Camadas do intertravamento de viga	Strati travi ad incastro	互锁梁层数
Interlocking beam width	Interlock-Struktur-Breite	Largeur du faisceau d’emboîtement	Ancho de viga de entrelazado	Largura do intertravamento de viga	Larghezza trave ad incastro	互锁梁宽度
Interlocking boundary avoidance	Vermeidung von Interlock-Strukturgrenzen	Évitement des limites de l’imbrication	Evitar los limites de entrelazado	Prevenção de fronteiras intertravadas	Evita confini con incastri	互锁与边界的留白量
Interlocking depth	Interlock-Struktur Tiefe	Profondeur d’emboîtement	Profundidad de entrelazado	Profundidade do intertravamento	Profondità incastro	互锁深度
Interlocking depth of a segmented region	Interlock-Struktur-Tiefe eines segmentierten Bereichs	Profondeur d’emboîtement d’une région segmentée	Profundidad de entrelazado de una región segmentada	Profundidade de intertravamento de uma região segmentada	Profondità di incastro regione segmentata	分割区域的交错深度
Interlocking direction	Interlock-Struktur Ausrichtung	Sens d’emboîtement	Dirección de entrelazado	Direção do intertravamento	Direzione incastro	互锁方向
Internal	Intern	Interne	Interno	Interno	Interno	内部
Internal bridge density	Interne Brücken Dichte	Densité du pont interne	Densidad de puente interno	Densidade de ponte interna	Densità ponti interni	内部桥接密度
Internal bridge flow ratio	Interne Brücken Flussrate	Ratio de débit du pont interne	Factor de flujo de puentes internos	Taxa de fluxo em ponte interna	Flusso di stampa ponti interni	内部搭桥流量比例
Internal bridge infill direction	Interne Brücken Füllrichtung	Direction du remplissage du pont interne	Dirección de relleno de puentes internos	Direção de preenchimento de ponte interna	Angolo riempimento ponti interni	内部桥接填充方向
Internal bridge only	Nur interne Brücke	Pont interne uniquement	Solo puente interno	Apenas pontes internas	Solo ponti interni	仅内部桥接
Internal ribs	Interne Rippen	Nervures internes	Refuerzos internos	Nervuras internas	Nervature interne	内部加强筋
Internal solid infill	Innere massive Füllung	Remplissage plein interne	Relleno sólido interno	Preenchimento sólido	Riempimento solido interno	内部实心填充
Internal solid infill flow ratio	Interne feste Füllung Durchflußrate	Ratio de débit du remplissage solide interne	Factor de flujo en relleno sólido interno	Taxa de fluxo em preenchimento sólido interno	Flusso di stampa riempimento solido interno	内部固体填充流动比
Internal solid infill pattern	Muster für das interne feste Füllmuster	Motif de remplissage plein interne	Patrón de relleno sólido interno	Padrão de preenchimento sólido interno	Motivo riempimento solido interno	内部实心填充图案
Intra-layer order	Intra-Schicht-Reihenfolge	Ordre intra-couche	Orden dentro de la capa	Ordem intra-camada	Ordine intra-strato	层内打印顺序
Ironing Pattern	Bügelmuster	Modèle de lissage	Patrón de alisado	Padrão do Alisamento	Motivo stiratura	熨烫模式
Ironing Support Interface	Glättung der Stützstruktur-Schnittstelle	Lissage de l'interface de support	Alisado de la interfaz de soporte	Alisamento da Interface de Suporte	Stiratura interfaccia supporto	支撑界面熨烫
Ironing Type	Glättungsmethode	Type de lissage	Tipo de alisado	Tipo de Alisamento	Tipo di stiratura	熨烫类型
Ironing angle offset	Glättwinkelversatz	Décalage de l'angle de lissage	Desplazamiento del ángulo de alisado	Delocamento de ângulo para alisamento	Angolo di stiratura	熨烫角度偏移
Ironing expansion	Glättungsausdehnung	Expansion du lissage	Ampliación de alisado	Expansão de alisamento	Espansione stiratura	熨烫扩展
Ironing flow	Materialmenge	Débit de lissage	Flujo de alisado	Fluxo do alisamento	Flusso stiratura	熨烫流量
Ironing inset	Glättabstand	Encastrement du repassage	Margen de alisado	Inserção do alisamento	Distanza stiratura dai bordi	熨烫内缩
Ironing line spacing	Abstand der Glättlinien	Espacement des lignes de lissage	Espaciado entre líneas de alisado	Espaçamento de linha do alisamento	Spaziatura linee di stiratura	熨烫间距
Ironing speed	Geschwindigkeit beim Glätten	Vitesse de lissage	Velocidad de alisado	Velocidade do alisamento	Velocità stiratura	熨烫速度
Junction Deviation	Junction-Deviation	Déviation de jonction		Desvio de Junção	Deviazione di giunzione	结点偏差
Label objects	Objekte beschriften	Label Objects	Etiquetar objetos	Etiquetar objetos	Etichetta oggetti	标注模型
Lateral Honeycomb	2D-Waben	Nid d'abeille latéral	Panal Lateral	Favo de Mel Lateral	Nido d'ape laterale	侧向蜂窝
Lateral Lattice	2D-Gitter	Treillis 2D	Enrejado Lateral	Treliça Lateral	Reticolo 2D	侧向向晶格
Lateral lattice angle 1	Gitterwinkel 1	Angle de treillis 1	Ángulo de Enrejado Lateral 1	Ângulo 1 de treliça lateral	Angolo reticolo 1	侧向晶格角度1
Lateral lattice angle 2	Gitterwinkel 2	Angle de treillis 2	Ángulo de Enrejado Lateral 2	Ângulo 2 de treliça lateral	Angolo reticolo 2	侧向晶格角度2
Layer Z		Couche z	Z de capa	Camada Z	Strato Z	层的 Z 坐标
Layer change G-code	Schichtwechsel G-Code	G-code de changement de couche	G-Code tras el cambio de capa	G-code de mudança de camada	G-code cambio strato	换层G-code
Layer height	Schichthöhe	Hauteur de couche	Altura de la capa	Altura da camada	Altezza strato	层高
Layer number	Schichtnummer	Numéro de couche	Número de capa	Número da camada	Numero dello strato	层编号
Layers and Perimeters	Schichten und Perimeter	Couches et Périmètres	Capas y Perímetros	Camadas e Perímetros	Strati e Perimetri	层和墙
Layers between ripple offset	Schichten zwischen Wellenversatz	Couches entre deux décalages d’ondulation	Capas con diferencia de ondulación	Camadas entre o deslocamento de onda	Strati deviazione increspature	波纹偏移之间的层数
Lightning	Blitz		Rayo	Relâmpago	Fulmine	闪电
Lightning overhang angle	Überhangwinkel der Blitzfüllung	Angle de surplomb Lightning	Ángulo de saliente del rayo			闪电悬垂角度
Limited filtering	Begrenzte Filterung	Filtrage limité	Filtrado limitado	Filtragem limitada	Filtraggio limitato	有限保留
Line	Linie	Ligne	Línea	Linha	Linea	线
Load assemble list	Lade die Liste der zusammenzufügenden Objekte	Charger la liste d’assemblage	Cargar lista de ensamblaje	Carregar lista de montagem	Carica elenco di assemblaggio	加载组合列表
Load custom G-code	Lade benutzerdefinierten G-Code	Charger un G-code personnalisé	Cargar G-Code personalizado	Carregar G-code personalizado	Carica G-code personalizzato	加载自定义 G-code
Load default filaments	Standard-Filamente laden	Charger les filaments par défaut	Cargar los filamentos por defecto	Carregar filamento padrão	Carica filamenti predefiniti	加载默认耗材
Locked Zag	Festes Zick-Zack	Zig Zag verrouillé	Zag Encerrado	Zague Travado		限定之字
Log file	Protokolldatei	Fichier journal	Archivo de registro			日志文件
Machine limits	Maschinengrenzen	Limites de la machine	Límites de la máquina	Limites da máquina	Limiti macchina	机器限制
Make overhangs printable	Überhang druckbar machen	Rendre les surplombs imprimables	Imprimir voladizos sin soportes	Tornar saliências imprimíveis	Rendi sporgenze stampabili	悬垂可打印化
Make overhangs printable - Hole area	Flächenbereich für druckbare Überhänge von Löchern	Rendre les surplombs imprimables - Zone de trous	Imprimir voladizos sin soportes - Área de orificios	Tornar saliências imprimíveis - Área do furo	Rendi sporgenze stampabili - Area foro	最大孔洞面积
Make overhangs printable - Maximum angle	Maximaler Winkel für druckbare Überhänge	Rendre les surplombs imprimables - Angle maximal	Imprimir voladizos sin soportes - Ángulo máximo	Tornar saliências imprimíveis - Ângulo máximo	Rendi sporgenze stampabili - Angolo massimo	悬垂可打印化的最大角度
MakerLab name	MakerLab-Name	Nom dans MakerLab	Nombre de MakerLab	Nome do MakerLab	Nome MakerLab	MakerLab 名称
MakerLab version	MakerLab-Version	Version de MakerLab	Versión de MakerLab	Versão do MakerLab	Versione MakerLab	MakerLab 版本
Manual Filament Change	Manueller Filamentwechsel	Changement manuel du filament	Cambio de Filamento Manual	Troca Manual de Filamento	Cambio manuale del filamento	手动更换丝材
Max	Maximal	Maximum		Máx	Massimo	最大
Max XY Smoothing	Maximale XY-Glättung	Lissage Max XY	Suavizado XY máximo	Suavização Máxima XY	Levigatura XY massima	最大XY平滑阈值
Max bridge length	Max Überbrückungslänge	Longueur max des ponts	Distancia máxima de puentes sin soporte	Comprimento máximo de ponte	Lunghezza massima ponti	最大桥接长度
Maximal bridging distance	Maximale Brückenlänge	Distance de pont maximale	Distancia máxima de puenteado	Distância máxima de ponte	Distanza massima di collegamento	最大桥接距离
Maximal layer Z	Maximale Schichtdicke Z	Couche maximale z	Z máxima de capa	Altura máxima da camada Z	Massimale strato Z	最顶层 Z 坐标
Maximum length of the infill anchor	Maximale Länge des Infill-Ankers	Longueur maximale de l’ancrage de remplissage	Máxima longitud del anclaje de relleno	Comprimento máximo da âncora de preenchimento	Lunghezza massima dell'ancoraggio del riempimento	填充锚线的最大长度
Maximum wall deviation	Maximale Wandabweichung	Écart maximal des parois	Desviación máxima de la pared	Desvio máximo de parede	Deviazione massima parete	最大墙体偏差
Maximum wall resolution	Maximale Wandauflösung	Résolution maximale des parois	Resolución máxima de la pared	Resolução máxima de parede	Risoluzione massima parete	最大墙体分辨率
Maximum width of a segmented region	Maximale Breite eines segmentierten Bereichs	Largeur maximale d’une région segmentée	Máximo ancho de una región segmentada	Largura máxima de uma região segmentada	Larghezza massima regione segmentata	分段区域的最大宽度
Maximum wipe tower print speed	Maximale Druckgeschwindigkeit des Reinigungsturms	Vitesse maximale d’impression de la tour d’essuyage	Velocidad máxima de impresión de la torre de purga	Velocidade máxima de impressão da torre de limpeza	Velocità massima di stampa della torre di spurgo	擦拭塔最大打印速度
Mesh margin	Abtastbereich	Marge de la maille	Margen de malla	Margem da malha	Margine matrice	网床边缘外扩
Min		Minimum		Mín	Minimo	最小
Minimize wall height angle	Minimale Wandhöhe Winkel	Angle de minimisation de la hauteur des parois	Minimizar el ángulo de la altura de capa	Minimizar o ângulo de altura das paredes	Riduci altezza su pareti inclinate	最小化墙高角度
Minimum Z height	Minimale Z-Höhe	Hauteur Z minimale	Altura Z mínima	Altura Z mínima	Altezza Z minima	最小 Z 高度
Minimum feature size	Minimale Merkmalgröße	Taille minimale de l'élément	Tamaño mínimo de la característica	Tamanho mínimo do elemento	Dimensione minima elementi	最小特征尺寸
Minimum non-zero part cooling fan speed	Minimale nicht-null Lüftergeschwindigkeit für die Teilekühlung	Vitesse minimale non nulle du ventilateur de refroidissement de pièce	Velocidad mínima no nula del ventilador de refrigeración	Velocidade mínima não-zero da ventoinha de resfriamento da peça		最小非零部件冷却风扇速度
Minimum save	Minimale Speicherung	Sauvegarde minimale	Salvado mínimo	Salvar mínimo	Salvataggio minimo	最小保存
Minimum sparse infill threshold	Mindestschwelle für Füllung	Seuil minimum de remplissage	Umbral de área mínima de relleno de baja densidad	Limiar mínimo de preenchimento esparso	Soglia minima riempimento sparso	稀疏填充最小阈值
Minimum wall length	Minimale Wandlänge	Longueur minimale de la paroi	Longitud mínima de perímetro	Comprimento mínimo da parede	Lunghezza minima parete	最短墙长度
Minimum wall width	Minimale Wandbreite	Largeur minimale de la paroi	Ancho mínimo del perímetro	Largura mínima de parede	Larghezza minima parete	最窄墙宽度
Minute			Minuto	Minuto	Minuto	分
Moderate	Moderat	Modéré	Moderado	Moderado	Moderato	适量
Monotonic	Monotonisch	Monotone	Monotónico	Monótono	Monotonico	单调
Monotonic line	Monotonische Linie	Ligne monotone	Línea Monotónica	Linha monótona	Linea monotonica	单调线
Month	Monat	Mois	Mes	Mês	Mese	月
Nearest	Nächste	La plus proche	Más cercano	Mais próximo	Più vicino	最近
No check	Keine Überprüfung	Pas de vérification	No comprobar	Sem verificação	Nessun controllo	不进行检查
No filtering	Keine Filterung	Pas de filtrage	Sin filtro	Sem filtragem	Nessun filtraggio	保留全部
No ironing	Kein Glätten	Pas de lissage	Sin alisado	Sem alisamento	Non stirare	不熨烫
No sparse layers (beta)	Keine dünnen Schichten (Beta)	Pas de couches éparses (beta)	Sin capas de baja densidad (beta)	Sem camadas esparsas (beta)	Nessuno strato sparso (beta)	无稀疏层 （实验功能）
None	Keine	Aucun	Ninguno	Nenhum	Nessuno	无
Normal (auto)	Normal (automatisch)			Normal (automático)	Normale (auto)	普通(自动)
Normal (manual)	Normal (manuell)	Normal (manuel)			Normale (manuale)	普通(手动)
Normal Support expansion	Normale Stützerweiterung	Expansion normale du support	Expansión de Soporte Normal	Expansão normal de suporte	Espansione supporti normali	普通支撑拓展
Normal printing	Normales Drucken	Impression normale	Impresión normal	Impressão normal	Stampa normale	普通打印
Normative check	Normative Überprüfung	Contrôle normatif	Comprobación de normativa	Verificação normativa	Controllo normativo	规范性检查
Nowhere	Nirgendwo	Nulle part	En ninguna parte	Nunca	Da nessuna parte	不填充
Nozzle HRC	Düse HRC	Dureté HRC buse	Dureza HRC de la boquilla	Bico HRC	HRC ugello	喷嘴洛氏硬度
Nozzle height	Düsenhöhe	Hauteur de la buse	Altura de la boquilla	Altura do bico	Altezza ugello	喷嘴高度
Number of extruders	Anzahl der Extruder	Nombre d’extrudeurs	Número de Cabezales	Número de extrusoras	Numero di estrusori	挤出机数量
Number of instances	Anzahl der Instanzen	Nombre d’instances	Número de instancias	Número de instâncias	Numero di istanze	实例数量
Number of objects	Anzahl der Objekte	Nombre d’objets	Número de objetos	Número de objetos	Numero di oggetti	对象数量
Number of ripples per layer	Anzahl der Wellen pro Schicht	Nombre d’ondulations par couche	Número de ondulaciones por capa	Número de ondulações por camada	Numero increspature per strato	每层的波纹数量
Number of slow layers	Anzahl der langsamen Schichten	Nombre de couches lentes	Número de capas lentas	Número de camadas lentas	Numero di strati lenti	慢速打印层数
Octagram Spiral	Oktagramm Spirale	Spirale Octagramme	Espiral Octagonal	Espiral de Octagrama	Spirale a ottogramma	八角螺旋
On build plate only	Nur auf Druckplatte	Sur plateau uniquement	Sólo en la cama de impresión	Apenas na placa de impressão	Solo sul piatto	仅在打印板生成
One wall threshold	Schwellenwert für eine Wand	Seuil de paroi unique	Umbral para generar un solo perímetro	Limiar de parede única	Soglia singola parete	单层墙阈值
Only one wall on first layer	Nur eine Wand in der ersten Schicht	Une seule paroi sur la première couche	Solo un perímetro en la primera capa	Parede única na primeira camada	Solo una parete sul primo strato	首层仅单层墙
Only one wall on top surfaces	Nur eine Wand auf den oberen Flächen	Une seule paroi sur les surfaces supérieures	Sólo un perímetro en las capas superiores	Parede única em superfícies superiores	Solo una parete su superfici superiori	顶面单层墙
Only overhangs	Nur an Überhängen	Sur les surplombs uniquement	Solo voladizos	Apenas saliências	Solo sporgenze	仅悬垂
Organic	Organisch	Arborescents Organiques	Orgánico	Orgânico	Organico	有机树
Orient Options	Orientierungsoptionen	Options d’orientation	Opciones de orientación	Opções de Orientação	Opzioni di orientamento	朝向选项
Other	Sonstiges	Autre	Otro	Outro	Altro	其他
Other layers filament sequence	Andere Schichten Filamentreihenfolge	Séquence de filament des autres couches	Secuencia de filamentos de otras capas	Sequência de impressão de outros filamentos	Sequenza di filamento degli altri strati	其他层的耗材打印顺序
Others	Sonstiges	Autre	Otros	Outros	Altro	其他
Outer wall	Außenwand	Paroi extérieure	Perímetro externo	Parede externa	Parete esterna	外墙
Outer wall flow ratio	Außenwand Durchflußrate	Ratio de débit de la paroi extérieure	Factor de flujo en perímetro exterior	Taxa de fluxo em parede externa	Flusso di stampa pareti esterne	外壁流量比
Outer walls	Äußere Wände	Parois externes	Paredes exteriores	Paredes externas		外墙
Outer/Inner	Außen/Innen	Extérieur/intérieur	Exterior/Interior	Exterior/Interior	Esterna/Interna	外墙/内墙
Output Model Info	Ausgabe Modellinformationen	Information du Modèle de Sortie	Información del modelo de salida	Emitir Informações do Modelo	Informazioni modello di output	输出模型信息
Output directory	Ausgabeverzeichnis	Répertoire de sortie	Directorio de salida	Diretório de saída	Cartella di destinazione	输出路径
Overhang flow ratio	Überhang Durchflußrate	Ratio de débit de surplomb	Factor de flujo en voladizos	Taxa de fluxo em saliência	Flusso di stampa sporgenze	悬垂流量比
Painted only	Nur lackiert	Peint uniquement	Solo pintado	Somente pintado	Solo verniciato	仅涂漆
Parallel printheads count	Anzahl der parallelen Druckköpfe	Nombre de têtes d’impression parallèles	Número de cabezales de impresión paralelos			并联打印头数量
Password	Passwort	Mot de passe	Contraseña	Senha		密码
Pattern angle	Winkel des Musters	Angle du motif	Ángulo del patrón	Ângulo de padrão	Angolo motivo	模式角度
Pause G-code	Pausen G-Code	G-code de mise en pause	G-Code de pausa	G-code de pausa	G-code pausa	暂停 G-code
Pellet Modded Printer	Pellet-Modifizierter Drucker	Imprimante à pellets	Impresora Modificada para Pellets	Impressora Modificada para Pellets	Stampante modificata per granuli	颗粒改装打印机
Per object	Pro Objekt	Par objet	Por objeto	Por objeto	Per oggetto	按对象
Perlin						柏林噪波
Physical printer name	Name des physischen Druckers	Nom de l’imprimante physique	Nombre físico de la impresora	Nome da predefinição física	Nome della stampante fisica	实际打印件名称
Polyhole detection margin	ab Wert erkenne Polyhole	Marge de détection des trous polygones	Margen de detección de poliorificios	Margem de detecção de polifuros	Margine di rilevamento poliforo	多边型孔检测边缘
Polyhole twist	Polyhole verdrehen	Torsion des trous polygones	Giro de poliorificio	Torção de polifuros	Torsione poliforo	扭曲多边型孔
Power Loss Recovery	Stromausfall Wiederherstellung	Récupération après coupure de courant	Recuperación tras pérdida de energía	Recuperação de Perda de Energia	Recupero da interruzione di corrente	断电恢复
Precise Z height	Präzise Z-Höhe	Hauteur précise du Z	Altura Z Precisa (beta)	Altura Z precisa	Altezza Z precisa	精准 Z 高度
Precise wall	Exakte Wand	Parois précises	Perímetro preciso	Parede precisa	Parete precisa	精准外墙尺寸
Preferred Branch Angle	Bevorzugter Astwinkel	Angle des branches préféré	Pendiente preferida de la rama	Ângulo preferido da ramificação	Angolo rami preferito	首选分支角度
Preferred orientation	Bevorzugte Ausrichtung	Orientation préférée	Orientación preferida	Orientação preferida	Orientamento preferito	零件朝向偏好
Preheat steps	Vorheizschritte	Étapes de préchauffage	Pasos de precalentamiento	Passos de pré-aquecimento	Fasi preriscaldamento	预热步骤
Preheat time	Vorheizzeit	Durée du préchauffage	Tiempo de Precalentamiento	Tempo de pré-aquecimento	Tempo di preriscaldamento	预热时间
Prime all printing extruders	Reinige alle Druckextruder	Amorcer tous les extrudeurs d’impression	Purgar todos los extrusores	Preparar todas as extrusoras de impressão	Prepara tutti gli estrusori di stampa	所有挤出机画线
Prime volume	Reinigungsvolumen	Volume d’amorçage	Volumen de purga	Volume de preparo	Volume torre di spurgo	清理量
Print infill first	Drucke zuerst die Füllung	Imprimer d’abord le remplissage	Imprimir relleno primero	Preenchimento primeiro	Stampa prima il riempimento	首先打印填充
Print preset name	Name der Druckprofile	Nom du préréglage d’impression	Imprimir nombre de perfil	Nome da predefinição de impressão	Nome del profilo di stampa	打印预设名称
Print sequence	Druckreihenfolge	Séquence d'impression	Secuencia de impresión	Sequência de impressão	Sequenza di stampa	打印顺序
Print time (normal mode)	Druckzeit (Normalmodus)	Temps d'impression (mode normal)	Tiempo de impresión (modo normal)	Tempo de impressão (modo normal)	Tempo di stampa (modalità normale)	打印耗时（正常模式）
Print time (seconds)	Druckzeit (Sekunden)	Temps d'impression (secondes)	Tiempo de impresión (segundos)	Tempo de impressão (segundos)	Tempo di stampa (secondi)	打印耗时（秒）
Print time (silent mode)	Druckzeit (Silent-Modus)	Temps d'impression (mode silencieux)	Tiempo de impresión (modo silencioso)	Tempo de impressão (modo silencioso)	Tempo di stampa (modalità silenziosa)	打印耗时（静音模式）
Printable height	Druckbare Höhe	Hauteur imprimable	Altura imprimible	Altura de impressão	Altezza di stampa	可打印高度
Printer	Drucker	Imprimante	Impresora	Impressora	Stampante	打印机
Printer Agent	Drucker-Agent	Agent d'imprimante	Agente de impresora	Agente de Impressora	Agente stampante	打印机代理
Printer configuration	Drucker Konfiguration	Configuration de l'imprimante	Configuración de la impresora	Configuração da impressora	Configurazione stampante	打印机配置
Printer notes	Druckernotizen	Notes de l’mprimante	Anotaciones de la impresora	Notas da impressora	Note stampante	打印机注释
Printer preset name	Name der Druckerprofile	Nom du préréglage de l’imprimante	Nombre de perfil de la impresora	Nome da predefinição de impressora	Nome del profilo della stampante	打印机预设名称
Printer structure	Druckerstruktur	Structure de l’imprimante	Estructura de la impresora	Estrutura da impressora	Struttura della stampante	打印机结构
Printer technology	Druckertechnologie	Technologie de l'imprimante	Tecnología de la impresora	Tecnologia da impressora	Tecnologia stampante	打印机类型
Printer type	Druckertyp	Type d’imprimante	Tipo de impresora	Tipo de impressora	Tipo stampante	打印机类型
Printer variant	Druckervariante	Variante de l’imprimante	Variante de la impresora	Variante da impressora	Variante stampante	打印机变种
Prune angle	Beschneidungswinkel	Angle d’élagage	Ángulo de recorte			修剪角度
Purge in prime tower	Reinige im Reinigungsturm	Purge dans la tour d’amorçage	Purgar en una torre	Purgar na torre de preparo	Usa torre di spurgo	冲刷进擦拭塔
Quality	Qualität	Qualité	Calidad	Qualidade	Qualità	质量
Quarter Cubic	Viertel kubisch	Quartier Cubique	Cuarto Cúbico	Quarto Cúbico	Quarto cubico	四分之一立方体
Radius		Rayon	Radio	Raio	Raggio	半径
Raft contact Z distance	Z Abstand Objekt Druckbasis 	Distance Z de contact du radeau	Distancia Z de contacto de la balsa (base de impresión)	Distância Z de contato da jangada	Distanza Z di contatto zattera	筏层Z间距
Raft expansion	Druckbasis Erweiterung	Agrandissement du radeau	Expansión de la balsa (base de impresión)	Expansão da jangada	Espansione della zattera	筏层扩展
Raft layers	Druckbasisschichten	Couches du radeau	Capas de balsa (base de impresión)	Camadas da jangada	Strati zattera	筏层
Random	Zufall	Aléatoire	Aleatorio	Aleatória	Casuale	随机
Rectilinear	Geradlinig	Rectiligne	Rectilíneo	Retilíneo	Rettilineo	直线
Rectilinear Interlaced	Rechteckiges Wechselmuster	Rectiligne Entrelacé	Entrelazado rectilíneo	Reticulado Interligado	Rettilineo Interlacciato	交叠的直线
Rectilinear grid	Rechtwinkliges Gitter	Grille rectiligne	Cuadrícula Rectilínea	Grade reticulada	Griglia rettilinea	直线网格
Reduce infill retraction	Rückzug bei der Füllung verringern	Réduire la rétraction du remplissage	Reducir la retracción del relleno	Reduzir retração durante o preenchimento	Evita retrazione nel riempimento	减小填充回抽
Regular	Regulär	Standard	Normal	Padrão	Regolare	常规
Relative bridge angle	Relativer Brückenwinkel	Angle de pont relatif	Ángulo de puente relativo			相对桥接角度
Repetition count	Anzahl der Wiederholungen	Nombre de répétitions	Cantidad de repeticiones	Contagem de repetições	Conteggio delle ripetizioni	重复次数
Resolution	Auflösung	Résolution	Resolución	Resolução	Risoluzione	分辨率
Resonance avoidance	Resonanzvermeidung	Évitement de résonance	Prevención de resonancia	Prevenção de ressonância	Prevenzione risonanza	共振规避
Reverse on even	Umkehren auf geraden Schichten	Inverser lors du passage pair	Invertir en los pares	Reversão em par	Inverti su strati pari	反转偶数层悬垂方向
Reverse only internal perimeters	Nur interne Umfänge umkehren	Inverser uniquement les périmètres internes	Invertir solo los perímetros internos	Reverter apenas os perímetros internos	Inverti solo pareti interne	仅反转内部墙壁
Reverse threshold	Umkehrschwelle	Seuil d’inversion	Umbral inverso	Limiar reverso	Soglia di inversione	反转阈值
Rib width	Rippenbreite	Largeur de la nervure	Ancho del refuerzo	Largura da nervura	Larghezza nervatura	加强筋宽度
Ridged Multifractal		Multifractal strié	Multifractal Rugoso	Multifractal estriado	Multifrattale ruvido	脊状多重分形
Ripple				Ondulação	Increspature	波纹
Ripple offset	Wellenversatz	Décalage des ondulations	Desplazamiento del ripple	Deslocamento das ondulações	Deviazione increspature	波纹偏移
Role base wipe speed	Rollenbasierte Wipe Geschwindigkeit	Vitesse d’essuyage en fonction de la vitesse d’extrusion	Velocidad de purga según tipo de línea	Velocidade de limpeza baseada na função	Velocità di spurgo basata su ruolo	自动擦拭速度
Rotate	Drehen	Pivoter	Rotar	Rotacionar	Ruota	旋转
Rotate around X	Rotieren um X	Rotation autour de X	Rotar alrededor de X	Rotacionar ao redor de X	Ruota attorno ad X	绕 X 旋转
Rotate around Y	Rotieren um Y	Rotation autour de l’axe Y	Rotar alrededor de Y	Rotacionar ao redor de Y	Ruota attorno ad Y	绕 Y 旋转
Same as top	Gleich wie oben	Identique au sommet	Lo mismo que la superior	Mesmo que superior	Come quello superiore	和顶部相同
Scale	Skalieren	Redimensionner	Escalar	Escala	Ridimensiona	缩放
Scan first layer	Erste Schicht scannen	Analyser la première couche	Escanear la primera capa	Escanear primeira camada	Scansiona primo strato	首层扫描
Scarf around entire wall	Schrägnaht um die gesamte Wand	Biseau sur toute la paroi	Bufanda en todo el perímetro	Cachecol em torno de toda a parede	Cucitura a sciarpa su intera parete	围绕整个围墙
Scarf joint flow ratio	Schrägnaht Flussverhältnis	Ratio de débit de la couture en biseau	Factor de flujo de la unión de bufanda	Taxa de fluxo em junta cachecol	Flusso di stampa cucitura a sciarpa	斜拼接缝流量
Scarf joint for inner walls	Schrägnaht für innere Wände	Joint en biseau pour les parois internes	Unión de bufanda para perímetros interiores	Junta cachecol em paredes internas	Cucitura a sciarpa per pareti interne	应用斜拼于内墙
Scarf joint seam (beta)	Schrägnaht (Beta)	Couture en biseau (beta)	Unión de bufanda en costuras (beta)	Costura junta cachecol (beta)	Cucitura a sciarpa (beta)	斜拼接缝（试验）
Scarf joint speed	Schrägnaht Geschwindigkeit	Vitesse de la couture en biseau	Velocidad de unión de bufanda	Velocidade da junta cachecol	Velocità cucitura a sciarpa	斜拼接缝速度
Scarf length	Länge der Schrägnaht	Longueur du biseau	Largo de la bufanda	Comprimento do cachecol	Lunghezza cucitura a sciarpa	斜拼接缝长度
Scarf start height	Starthöhe der Schrägnaht	Hauteur de départ du biseau	Altura de inicio de la bufanda	Altura inicial do cachecol	Altezza iniziale cucitura a sciarpa	斜拼接缝起始高度
Scarf steps	Schrägnaht Schritte	Étapes du biseau	Pasos de la bufanda	Degraus do cachecol	Incrementi cucitura a sciarpa	斜拼段数
Seam gap	Naht Zwischenraum	Écart de couture	Separación entre costuras	Vão entre costuras	Spazio di cucitura	接缝间隔
Seam position	Nahtposition	Position de la couture	Posición de la costura	Posição da costura	Posizione cucitura	接缝位置
Second	Sekunde	Seconde	Segundo	Segundo	Secondo	秒
Send progress to pipe	Fortschritt an die Leitung senden	Envoyer la progression à la queue	Enviar el progreso a la tubería	Enviar o progresso para a fila	Invia l'avanzamento al pipe	将进度发送到管道
Serial Number	Seriennummer	Numéro de série	Número de serie	Número de Série		序列号
Set other flow ratios	Andere Flussverhältnisse festlegen	Définir d'autres ratios de débit	Establecer otros ratios de flujo	Definir outros fluxos	Imposta altri rapporti di flusso	设置其他流量比
Show auto-calibration marks	Zeige automatische Kalibrierungsmarkierungen	Afficher les marques de calibration	Muestra marcas de autocalibración	Mostrar marcas de autocalibração automática	Mostra segni di autocalibrazione	显示雷达校准线
Single Extruder Multi Material	Einzelner Extruder, mehrere Materialien	Multi-matériaux pour extrudeur unique	Multi Material con Extrusor Único	Multimaterial com Extrusora Única	Estrusore singolo multimateriale	单挤出机多材料
Single loop after first layer	Single Loop nach der ersten Schicht	Boucle unique après la première couche	Un solo bucle después de la primera capa	Volta única depois da primeira camada	Singolo giro dopo il primo strato	首层后单圈
Skeleton infill density	Dichte der Skelettfüllung	Densité du remplissage squelette	Densidad del esqueleto del relleno	Densidade de preenchimento de esqueleto	Densità riempimento scheletro	骨架填充密度
Skeleton line width	Linienbreite der Skelettfüllung	Largeur de ligne du squelette	Ancho de línea del esqueleto	Largura da linha do esqueleto	Larghezza linea scheletro	骨架线宽
Skin infill density	Dichte der Außenhautfüllung	Densité du remplissage de la peau	Densidad de la piel del relleno	Densidade de preenchimento de textura	Densità riempimento pelle	外壳填充密度
Skin infill depth	Tiefe der Außenhautfüllung	Profondeur du remplissage de la peau	Profundidad de la capa superficial	Profundidade de preenchimento de textura	Profondità riempimento pelle	外壳填充深度
Skin line width	Linienbreite der Außenhautfüllung	Largeur de ligne de la peau	Ancho de línea de la piel	Largura da linha da textura	Larghezza linea pelle	外壳线宽
Skip modified G-code in 3MF	Überspringe geänderte G-Codes in 3mf	Ignorer le G-code modifié dans le 3MF	Omitir G-code modificado en 3MF	Pular G-code modificado em 3MF	Salta G-code modificati nel 3mf	跳过 3MF 中修改过的 G-code
Skip points	Punkte überspringen	Sauter des points	Omitir puntos	Pular pontos	Salta punti	跳过点
Skirt distance	Abstand der Umrandung	Distance de la jupe	Distancia de falda	Distância da saia	Distanza gonna	裙边距离
Skirt height	Höhe der Umrandungsringe	Hauteur de la jupe	Altura de falda	Altura da saia	Altezza gonna	裙边高度
Skirt loops	Anzahl Umrandungsringe	Boucles de la jupe	Bucles de la falda	Voltas da saia	Perimetri gonna	裙边圈数
Skirt minimum extrusion length	Minimale Extrusionslänge der Umrandung	Longueur minimale d’extrusion de la jupe	Longitud mínima de extrusión de la falda	Comprimento mínimo de extrusão da saia	Lunghezza minima di estrusione gonna	裙边最小挤出长度
Skirt speed	Druckgeschwindigkeit der Umrandung	Vitesse de la jupe	Velocidad de falda	Velocidade da saia	Velocità gonna	裙边速度
Skirt start point	Startpunkt der Umrandung	Point de départ de la jupe	Punto de inicio de la falda	Ponto de partida da saia	Punto di inizio gonna	裙边起始点
Skirt type	Art der Umrandung	Type de jupe	Tipo de falda	Tipo de saia	Tipo di gonna	裙边类型
Slice		Découper	Laminar	Fatiar	Elabora	切片
Slice gap closing radius	Slice-Lückenschlussradius	Rayon de fermeture de l’écart des tranches	Radio de cierre de laminado	Raio de fechamento de vãos de fatiamento	Raggio di chiusura spazi vuoti	切片间隙闭合半径
Slicing Mode	Slicing-Modus	Mode de découpe	Modo de laminado	Modo de Fatiamento	Modalità elaborazione	切片模式
Slow down for curled perimeters	Langsamer Druck für gekrümmte Umfänge	Ralentir lors des périmètres courbés	Reducir velocidad en perímetros curvados	Reduzir vel. para perímetros encurvados	Rallenta per pareti incurvate	翘边降速
Slow down for overhang	Verlangsamen bei Überhängen	Ralentir pour le surplomb	Disminuir velocidad en voladizos	Reduzir velocidade em saliências	Rallenta in caso di sporgenze	悬垂降速
Small area flow compensation (beta)	Kleine Flächen-Flusskompensation (Beta)	Compensation du débit des petites zones (beta)	Compensación de flujo en áreas pequeñas (beta)	Compensação de fluxo de área pequena (beta)	Compensazione del flusso su piccola area (beta)	小区域填充流量补偿（试验）
Small perimeters	Feine Strukturen	Petits périmètres	Perímetros pequeños	Pequenos perímetros	Perimetri piccoli	微小部位
Small perimeters threshold	Schwelle für kleine Strukturen	Seuil des petits périmètres	Umbral de Perímetros pequeños	Limiar de pequenos perímetros	Soglia perimetri piccoli	微小部位周长阈值
Smooth Spiral	Gleichmäßig Spirale	Spirale lisse	Espiral suave	Espiral Suave	Spirale liscia	光滑螺旋模式
Smoothing segment length	Segmentlänge für die Glättung	Longueur du segment de lissage	Longitud del segmento de suavizado	Comprimento do segmento de suavização	Lunghezza del segmento di livellamento	平滑段长度
Snug	Nahtlos	Ajusté	Ajustado	Ajustado	Aderente	紧贴
Solid infill direction	Richtung des massiven Füllmusters	Direction du remplissage	Dirección del relleno sólido	Direção do preenchimento sólido	Direzione riempimento solido	实心填充方向
Solid infill rotation template	Rotationsvorlage für massive Füllung	Modèle de rotation du remplissage solide	Plantilla de rotación del relleno sólido	Gabarito de rotação de preenchimento sólido	Rotazione del riempimento solido	实心填充旋转模板
Sparse infill	Füllung	Remplissage	Relleno poco denso	Preenchimento esparso	Riempimento sparso	稀疏填充
Sparse infill anchor length	Länge des Infill-Ankers	Longueur de l’ancrage de remplissage interne	Longitud del anclaje de relleno de baja densidad	Comprimento da âncora de preenchimento esparso	Lunghezza ancoraggio riempimento sparso	稀疏填充锚线长度
Sparse infill density	Fülldichte	Densité de remplissage	Densidad de relleno de baja densidad	Densidade do preenchimento esparso	Densità riempimento sparso	稀疏填充密度
Sparse infill direction	Richtung des einfachereren Fülling	Direction du remplissage	Dirección de relleno de baja densidad	Direção do preenchimento esparso	Direzione riempimento sparso	稀疏填充方向
Sparse infill flow ratio	Dünne Füllung Durchflußrate	Ratio de débit du remplissage clairsemé	Factor de flujo en relleno	Taxa de fluxo em preenchimento esparso	Flusso di stampa riempimento sparso	稀疏填充流量比
Sparse infill pattern	Füllmuster	Motif de remplissage	Patrón de relleno de baja densidad	Padrão de preenchimento esparso	Motivo riempimento sparso	稀疏填充图案
Sparse infill rotation template	Infill-Rotationsvorlage	Modèle de rotation du remplissage clairsemé	Plantilla de rotación del relleno	Gabarito de rotação de preenchimento esparso	Modello di rotazione riempimento sparso	稀疏填充旋转模板
Speed	Geschwindigkeit	Vitesse	Velocidad	Velocidade	Velocità	速度
Spiral finishing flow ratio	Spirale Endflussverhältnis	Taux de débit de la finition en spirale	Factor de flujo final en espiral	Taxa de fluxo de acabamento de espiral	Flusso finale spirale	螺旋结束流量比
Spiral starting flow ratio	Spirale Startflussverhältnis	Rapport de débit de départ de la spirale	Factor de flujo inicial en espiral	Taxa de fluxo inicial de espiral	Flusso iniziale spirale	螺旋开始流量比
Spiral vase	Vasenmodus	Vase spirale	Vaso en espiral	Vaso espiral	Vaso a spirale	旋转花瓶
Split	Teilen	Scinder	Dividir	Dividir	Dividi	拆分
Stabilization cone apex angle	Winkel des Stabilisierungskegels	Angle au sommet du cône de stabilisation	Ángulo de vértice del cono de estabilización	Ângulo do ápice do cone de estabilização	Angolo apice cono di stabilizzazione	稳定锥体顶角
Staggered inner seams	Versetzte innere Nähte	Coutures intérieures décalées	Costuras interiores escalonadas	Costuras internas escalonadas	Cuciture interne sfalsate	交错的内墙接缝
Start G-code	Start G-Code	G-code de démarrage	G-Code inicial	G-code Inicial	G-code iniziale	起始G-code
Straightening angle	Begradigungswinkel	Angle de redressement	Ángulo de enderezado			拉直角度
Strength	Struktur	Solidité	Fuerza	Resistência	Resistenza	强度
Style	Stil		Estilo	Estilo	Stile	样式
Support	Stützen	Supports	Soportes	Suporte	Supporto	支撑
Support Cubic	Kubisch Stützen	Support Cubique	Soporte Cúbico	Cúbico de Suporte	Supporto cubico	支撑立方体
Support Ironing Pattern	Stützstruktur-Glättungsmuster	Motif de lissage des supports	Patrón de alisado de soporte	Padrão de Alisamento de Suporte	Trama stiratura supporto	支撑熨烫图案
Support Ironing flow	Stützstruktur-Glättungsfluss	Débit de lissage des supports	Flujo de alisado de soporte	Fluxo de Alisamento de Suporte	Flusso stiratura supporto	支撑熨烫流量
Support Ironing line spacing	Stützstruktur-Glättungslinienabstand	Espacement des lignes de lissage des supports	Espaciado de las líneas de alisado de soporte	Espaçamento linhas no Alisamento de Suporte	Spaziatura linee stiratura supporto	支撑熨烫线间距
Support air filtration	Luftfilterung unterstützen	Filtration de l’air	Función de filtración de aire	Filtragem de ar de suporte	Supporto filtrazione aria	支持空气过滤
Support control chamber temperature	Druckkammer-Temperatursteuerung	Contrôle de température du caisson	Función de control de temperatura de cámara	Controlar a temperatura da câmara de suporte	Supporto controllo temperatura camera di stampa	支持仓温控制
Support critical regions only	Nur kritische Bereiche stützen	Ne créer des supports que pour les régions critiques	Añadir soportes en regiones críticas solo	Suportar apenas regiões críticas	Supporta solo aree critiche	仅支撑关键区域
Support flow ratio	Support Durchflußrate	Ratio de débit des supports	Factor de flujo para soportes	Taxa de fluxo em suporte	Flusso di stampa supporti	支撑流量比
Support interface	Stützstruktur-Schnittstelle	Interface de support	Interfaz de soporte	Interface de suporte	Interfaccia di supporto	支撑面
Support interface flow ratio	Support-Schnittstellen-Durchflußrate	Ratio de débit de l'interface de support	Factor de flujo de la interfaz de soporte	Taxa de fluxo em interface de suporte	Flusso di stampa interfaccie supporti	支撑面流量比例
Support multi bed types	Unterstützung mehrerer Betttypen	Prise en charge de plusieurs types de plateaux	Usar tipos de cama múltiples	Suportar vários tipos de placa	Supporto tipi di piatti multipli	支持多种打印床类型
Support parallel printheads	Unterstützung paralleler Druckköpfe	Prise en charge des têtes d’impression parallèles	Compatibilidad con cabezales de impresión paralelos			支持并联打印头
Support wall loops	Wände um Stützstrukturen	Boucles de paroi de support	Bucles de perímetro de apoyo	Voltas de parede de suporte	Perimetri supporto	支撑外墙层数
Support/object XY distance	Stützen/Objekt XY-Abstand	Distance support/objet xy	Distancia soporte/objeto X-Y	Distância XY entre suporte e objeto	Distanza XY supporto/oggetto	支撑/模型xy间距
Support/object first layer gap	Stützen/Objekt Abstand der ersten Schicht	Écart de première couche support/objet	Separación soporte/objeto en la primera capa	Vão na primeira camada entre suporte e objeto	Spazio supporto/oggetto primo strato	支撑/对象首层间距
Support/raft base	Stütz-/Basis-Objekt	Support/base du radeau	Capa base/balsa	Base de suporte/jangada	Base supporto/zattera	支撑/筏层主体
Support/raft interface	Stütz-/Raft-Schnittstelle	Support/base d'interface	Interfaz de soporte/balsa	Interface de suporte/jangada	Interfaccia supporto/zattera	支撑/筏层界面
Supports silent mode	Unterstützt den Leise-Modus	Prend en charge le mode silencieux	Admite el modo silencioso	Suporta modo silencioso	Supporto modalità silenziosa	支持静音模式
Symmetric infill Y axis	Symmetrische Füllung Y-Achse	Axe Y de remplissage symétrique	Relleno simétrico respecto al eje Y	Preenchimento simétrico no eixo Y	Riempimento simmetrico asse Y	对称填充Y轴
TPMS-D						TPMS-D结构
TPMS-FK						TPMS-FK结构
Temperature variation	Temperaturvariation	Variation de température	Variación de temperatura	Variação de temperatura	Variazione di temperatura	软化温度
The number of other layers print sequence	Die Anzahl der anderen Schichten Druckreihenfolge	Le nombre d’autres couches de la séquence d’impression	El número de secuencias de impresión de otras capas	O número de sequência de impressão das outras camadas	Numero sequenza di stampa degli altri strati	其他层的打印顺序数量
Thick external bridges	Dicke externe Brücken	Ponts extérieurs épais	Puentes externos gruesos	Pontes externas grossas	Ponti esterni spessi	外部搭桥用厚桥
Thick internal bridges	Dicke interne Brücken	Ponts internes épais	Puentes gruesos internos	Pontes internas grossas	Ponti interni spessi	内部搭桥用厚桥
Threshold angle	Schwellenwinkel	Angle de seuil	Pendiente máxima	Ângulo limiar	Angolo di soglia	阈值角度
Threshold overlap	Schwellwertüberlappung	Chevauchement du seuil	Umbral de solapamiento	Sobreposição de limiar	Soglia sovrapposizione	阈值支撑比例
Time cost	Druckzeit Kosten	Coût horaire	Coste monetario por hora	Custo de tempo	Costo orario	耗时
Timelapse	Zeitraffer					延时摄影
Timelapse G-code	Zeitraffer G-Code	G-code de Timelapse	G-Code de timelapse	G-code de timelapse	G-code timelapse	延时摄影G-code
Timestamp	Zeitstempel	Horodatage	Marca de tiempo	Data/hora	Marca temporale	时间戳
Tip Diameter	Durchmesser der Spitze	Diamètre de la pointe	Tamaño de la punta	Diâmetro da ponta	Diametro della punta	尖端直径
Tool change on wipe tower	Werkzeugwechsel auf dem Reinigungsturm	Changement d’outil sur la tour d’essuyage	Cambio de herramienta en la torre de purga	Troca de ferramenta na torre de limpeza		在擦拭塔上换头
Tool change time	Werkzeugwechselzeit	Délais nécessaire au changement d’outil	Tiempo de cambio de herramienta	Tempo de troca de ferramenta	Durata cambio testina	换工具头所需时间
Top Z distance	Oberer Z-Abstand	Distance Z supérieure	Distancia Z superior	Distância Z superior	Distanza Z superiore	顶部Z距离
Top and bottom surfaces	Obere und untere Oberflächen	Surfaces supérieure et inférieure	Superficies superior e inferior	Superfícies superior e inferior	Superfici superiori e inferiori	仅顶层和底层
Top interface layers	Obere Schnittstellenschichten	Couches d'interface supérieures	Capas de la interfaz superior	Camadas de interface superior	Strati interfaccia superiore	顶部接触面层数
Top interface spacing	Oberer Schnittstellenabstand	Espacement de l'interface supérieure	Espaciado de la interfaz superior	Espaçamento da interface superior	Spaziatura interfaccia superiore	顶部接触面线距
Top shell layers	Obere Schalenschichten	Couches supérieures de la coque	Capas de la cubierta superior	Camadas de topo da casca	Strati guscio superiore	顶部壳体层数
Top shell thickness	Dicke der oberen Schale	Épaisseur de la coque supérieure	Espesor mínimo de la cubierta superior	Espessura da casca do topo	Spessore guscio superiore	顶部壳体厚度
Top surface	Obere Oberfläche	Surface supérieure	Relleno sólido superior	Superfície superior	Superficie superiore	顶面
Top surface density	Dichte der oberen Oberfläche	Densité de la surface supérieure	Densidad de la superficie superior	Densidade da superfície superior	Densità superficie superiore	顶面密度
Top surface flow ratio	Durchflussverhältnis obere Fläche	Ratio du débit des surfaces supérieures	Factor de flujo en superficie superior	Taxa de fluxo em superfície superior	Flusso di stampa superficie superiore	顶部表面流量比例
Top surface pattern	Muster der Oberfläche	Motif de la surface supérieure	Patrón de relleno cubierta superior	Padrão de superfície superior	Motivo superfice superiore	顶面图案
Top surfaces	Obere Oberflächen	Surfaces supérieures	Todas las superficies superiores	Superfícies superiores	Superfici superiori	顶面
Top/Bottom solid infill/wall overlap	Überlappung des oberen/unteren massiven Füllung/Wand	Chevauchement du remplissage ou de la paroi supérieur(e)/inférieur(e)	Solape de relleno sólido superior/inferior y perímetro	Sobreposição Superior/Inferior de preenchimento sólido/parede	Sovrapposizione riempimento solido superiore/inferiore e parete	顶/底部实心填充/墙重叠率
Topmost surface	Oberste Oberfläche	Surface la plus élevée	Sólo la superficie superior	Superfície superior mais alta	Superficie superiore più alta	最顶面
Total cost	Geamtkosten	Coût total	Costo total	Custo total	Costo totale	总成本
Total layer count	Gesamtanzahl der Schichten	Nombre total de couches	Recuento total de capas	Total de camadas	Numero totale di strati	总层数
Total tool changes	Gesamte Anzahl der Werkzeugwechsel	Nombre total de changements d’outils	Total de cambios de cabezales	Total de trocas de ferramenta	Totale cambi di testina	总工具更换次数
Total volume	Gesamtvolumen	Volume total	Volumen total	Volume total	Volume totale	总体积
Total weight	Gesamtgewicht	Poids total	Peso total	Peso total	Peso totale	总重量
Total wipe tower cost	Gesamtkosten des Reinigungsturms	Coût total de la tour de purge	Costo total de torre de purga	Custo total da torre de limpeza	Costo totale torre di pulizia	擦拭塔总成本
Travel	Eilgang	Déplacement	Desplazamientos	Deslocamento	Spostamento	空驶
Tree (auto)	Baum (automatisch)	Arbre (auto)	Árbol (auto)	Árvore (automático)	Ad albero (auto)	树状(自动)
Tree (manual)	Baum (manuell)	Arbre (manuel)	Árbol (manual)	Árvore (manual)	Ad Albero (manuale)	树状(手动)
Tree Hybrid	Baum-Hybrid	Arborescent Hybride	Árbol Híbrido	Árvore Híbrida	Albero ibrido	混合树
Tree Slim	Baum schlank	Arborescent Fin	Árbol Delgado	Árvore Estreita	Albero sottile	苗条树
Tree Strong	Baum stark	Arborescent Fort	Árbol Fuerte	Árvore Forte	Albero spesso	粗壮树
Tree support branch angle	Baumstütze Astwinkel	Angle de branche support arborescent	Ángulo de las rama de soporte Árbol	Ângulo da ramificação da árvore de suporte	Angolo rami supporti ad albero	树状支撑分支角度
Tree support branch diameter	Durchmesser des Stützastes eines Baumes	Diamètre de branche de support arborescent	Diámetro de la rama de soporte del árbol	Diâmetro do ramo de suporte de árvore	Diametro rami supporti ad albero	树状支撑分支直径
Tree support branch distance	Abstand der Baumstützenäste	Distance de branche de support arborescent	Distancia de la rama de soporte del árbol	Distância entre ramificações	Distanza rami supporti ad albero	树状支撑分支距离
Tree support brim width	Baumsupport mit Füllung	Largeur de bordure du support arborescent	Anchura del borde de adherencia	Largura da borda de suporte de árvore	Larghezza tesa supporto ad albero	树状支撑裙边宽度
Tree support with infill	Baumsupport mit Füllung	Support arborescent avec remplissage	Soporte de Árbol con relleno	Suporte de árvore com preenchimento	Riempimento supporti ad albero	树状支撑生成填充
Tri-hexagon	Tri-Hexagon	Tri-hexagone	Tri-hexágono	Tri-hexágono	Tri-esagono	内六边形
Triangles	Dreiecke		Triángulos	Triângulos	Triangoli	三角形
Type	Typ		Tipo	Tipo	Tipo	类型
Undefine	Undefiniert	Non défini	Indefinido	Não definido	Indefinito	未定义
UpToDate	Auf dem neuesten Stand	À jour	Actualizado	Atualizar	Aggiorna	同步最新设置
Use 3MF instead of G-code						使用 3MF 代替 G-code
Use 3rd-party print host	Benutze Drittanbieter-Druck-Hosts	Utiliser un hôte d’impression tiers	Utilizar host de impresión de terceros	Usar host de impressão de terceiros	Usa un host di stampa di terze parti	启用第三方网络连接
Use beam interlocking	Verwende Interlock-Strukturen	Utiliser l’emboîtement des poutres	Usar entrelazado de vigas	Usar intertravamento de viga	Usa trave ad incastro	启用互锁梁
Use firmware retraction	Filament Rückzug durch Firmware	Utiliser la rétraction firmware	Usar retracción de firmware (beta)	Usar retração de firmware	Usa retrazione firmware	使用固件回抽
Use relative E distances	Relative Extrusion	Utiliser l’extrusion relative	Usar distancias E relativas	Usar distâncias E relativas	Usa distanze E relative	使用相对E距离
Used filament	Genutztes Filament	Filament utilisé	Filamento usado	Fil. usado	Filamento usato	已用耗材
User	Benutzer	Utilisateur	Usuario	Usuário	Utente	用户名
Verbose G-code	ausführlicher G-Code	G-code commenté	G-Code detallado	G-code detalhado	G-code verboso	注释G-code
Voronoi						维诺图
Wall distribution count	Anzahl der Wände	Nombre de parois distribuées	Recuento de la distribución del perímetro	Contagem de distribuição de paredes	Conteggio distribuzione parete	墙分布计数
Wall generator	Wandgenerator	Générateur de paroi	Generador de perímetros	Gerador de paredes	Generatore parete	墙生成器
Wall loop direction	Druck-Richtung der Wand	Direction de la paroi	Dirección del bucle de perímetro	Direção da volta da parede	Direzione perimetri di stampa	围墙打印方向
Wall loops	Wandschleifen	Nombre de parois	Bucles de perímetro	Voltas da parede	Perimetri di stampa	墙层数
Wall transition length	Länge des Wandübergangs	Longueur de la paroi de transition	Anchura de transición de perímetro	Comprimento da transição de parede	Lunghezza transizione parete	墙过渡长度
Wall transitioning filter margin	Filter für die Größe des Wandübergangs	Marge du filtre de transition de paroi	Margen del filtro de transición al perímetro	Margem de filtro de transição de parede	Margine filtro transizione parete	墙过渡过滤间距
Wall transitioning threshold angle	Schwellenwinkel für den Wandübergang	Angle du seuil de transition de la paroi	Ángulo del umbral de transición del perímetro	Ângulo limiar de transição de parede	Angolo soglia transizione parete	墙过渡阈值角度
Wall type	Wandtyp	Type de paroi	Tipo de pared	Tipo de parede	Tipo di parete	墙类型
Walls printing order	Anordnung der Wände	Ordre d’impression des parois	Orden de impresión de perímetros	Ordem de impressão das paredes	Ordine stampa pareti	墙顺序
Width	Breite	Largeur	Ancho	Largura	Larghezza	宽度
Wipe before external loop	Wischbewegung vor äußerer Schleife	Essuyer avant la boucle externe	Purgado antes del bucle externo	Limpeza antes da volta externa	Spurgo prima del perimetro esterno	额外的外墙打印前擦拭
Wipe on loops	Wischbewegung nach innen	Essuyer sur les boucles	Purgado en contornos curvos	Limpeza em voltas	Spurgo sui perimetri di stampa	闭环擦拭
Wipe speed	Wipe Geschwindigkeit	Vitesse d’essuyage	Velocidad de purgado	Velocidade de limpeza	Velocità di spurgo	擦拭速度
Wipe tower	Reinigungsturm	Tour d’essuyage	Torre de purga	Torre de limpeza	Torre di spurgo	擦拭塔
Wipe tower purge lines spacing	Wischabstand der Reinigungsturmpurges	Espacement des lignes de purge de la tour d’essuyage	Espaciado de las líneas de la torre de purga	Espaçamento das linhas de purga da torre de limpeza	Spaziatura linee torre di spurgo	擦拭塔冲刷线间距
Wipe tower rotation angle	Winkel der Reinigungsturmrotation	Angle de rotation de la tour d’essuyage	Ángulo de rotación de torre de purga	Ângulo de rotação da torre de limpeza	Angolo di rotazione della torre di spurgo	擦拭塔旋转角度
Wipe tower type	Reinigungsturm-Typ	Type de tour de purge	Tipo de torre de purga	Tipo de torre de limpeza	Tipo di torre di spurgo	擦拭塔类型
Wipe tower volume	Reinigungsturmvolumen	Volume de la tour de purge	Volumen de torre de purga	Volume da torre de limpeza	Volume torre di pulizia	擦拭塔体积
X-Y contour compensation	X-Y-Konturkompensation	Compensation de contour X-Y	Compensación de contornos en X-Y	Compensação de contornos XY	Compensazione contorni X-Y	X-Y 外轮廓尺寸补偿
X-Y hole compensation	X-Y-Loch-Kompensation	Compensation de trou X-Y	Compensación en X-Y de huecos	Compensação de furos XY	Compensazione fori X-Y	X-Y 孔洞尺寸补偿
Year	Jahr	Année	Año	Ano	Anno	年
Z contouring enabled	Z Konturierung aktiviert	Contournage en Z activé	Perfilado Z activado	Contorno em Z habilitado	Contornatura Z abilitata	启用 Z 层抗锯齿
Z offset	Z-Offset	Décalage Z	Desplazamiento de Z	Deslocamento Z	Compensazione Z	Z偏移
Z-buckling bias optimization (experimental)	Z-Buckling-Bias-Optimierung (experimentell)	Optimisation du biais de flambage en Z (expérimental)	Optimización del desplazamiento por deformación en Z (experimental)			Z 轴屈曲偏置优化（实验性）
Zig Zag	Zick-Zack			Zigue-Zague		之字形
accel_to_decel	Beschleunigung zu Verzögerung	ajuster l’accélération à la décélération				制动速度
mstpp					tmepp	材料温度暂停
mtcpp					nmtpp	材料温度补偿
"""#
}
