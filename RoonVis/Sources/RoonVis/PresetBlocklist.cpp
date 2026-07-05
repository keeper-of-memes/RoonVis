#include "PresetBlocklist.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <string_view>

namespace RoonVis
{
namespace
{

constexpr const char *kKnownSlowPresetFilenames[] = {
    "amandio_c_-_prime_forms_keylontiq_pseudoskienke_blanco_membership_tape_aural_plastcopule.milk",
    "flexi_-_mindblob_2-0_rv_cn_jelly_v4.milk",
    "Jc_-_Quantum_Processing.milk",
    "Krash_Rovastar_-_Cerebral_Demons_-_Phat_EoS_Stars_Remix.milk",
    "Phat_Emale_-_best_halfbaked_reversed_Remix.milk",
    "Stahlregen_Boz_-_Machine_Code_Reaction_Diffusion_qrimbinael_dogmbath.milk",
    "Stahlregen_Geiss_ORB_-_Etheral_Waves_3_layers_of_Rayleigh_RMX_1_-_var_nz.milk",
    "stbenge_-_dripping_piles_B_gained_outside_of_mistranslation_dare_rid_vs_tour_ying_fixatives.milk",
    "suksma_-_beyond_imbalance_understate_-_dyst2_-_flacc.milk",
    "suksma_-_byT_o_the_bublee_you_nz_not_knowing_is_the_best.milk",
    "suksma_-_bristle_slime_monster_friend_shf.milk",
    "suksma_-_chemosynthetic_nosferatu_-_automating_transformation_with_b_n_s3.milk",
    "suksma_-_chemosynthetic_nosferatu_-_automating_transformation_-_claim_form_fsh_shf_flx_obl_roam3_nz.milk",
    "suksma_-_flexi_coheres_vacuum_energy_-_brujchump_-_kunwei.milk",
    "suksma_-_kanvas_the_aerea_-_couldn_t_not.milk",
    "suksma_-_ku_pilled_-_forgoing_utility.milk",
    "suksma_-_mtn_flx_-_flacc_roam3_ye_olde_rotgasm.milk",
    "suksma_-_no_bottom_-_lofted_guts_-_777_flacc.milk",
    "suksma_-_water_cooled_red_uranium_vs_dotes_-_crowded_absolution_-_flacc_matter_density_template.milk",
    "goody_2_stahlregen_2_fed_-_2nd_collaboration_ps2-0_-_5.milk",
    "Krash_yin_-_Electric_universe_nuclear_secrets_Phat_Carbon_mix.milk",
    "undulate_harque_-_amaz_inge_nz_ygtbfkm.milk",
    // Curated 2026-07-04 from a device burn-in with live audio (render ms/frame noted):
    "fiShbRaiN_Flexi_-_witchcraft_unleashed_00_the_template.milk",              // 2282ms
    "fiShbRaiN_-_witchcraft_metropolish_remix_-_test_-_tillex_-_mpreten_ya_don_liq_me_bawlce.milk", // 1353ms
    "cleave_and_cleave_to_thine_w_thankee_sai_for_more_trippy_ass_shit_hail.milk", // 1019ms
    "GreatWho_Flexi_-_Lasershow_bipolar_team_party.milk",                       // 816ms
    "SUE3DD_1.milk",                                                            // 602ms
    "suksma_-_undead_stem_nz_zyl_into_significan_t2.milk",                      // 550ms
    // Curated 2026-07-04 from the full-pack device sweep with live audio (peak >=200ms/frame).
    // Attribution (frame-breakdown probes): dominated by per-shape-instance draw overhead
    // (~1ms/instance through ANGLE; presets request 1300-2500 instances/frame) — not fixable
    // by eval acceleration; shape-instancing in the renderer is the future rescue path.
    "305.milk",
    "EoS_-_glowsticks_v2_05_and_proton_lights_Krash_s_beat_code_Phat_remix07_demons_eye.milk",
    "Flexi_-_evolution_6_c.milk",
    "Geiss_-_Cosmic_Dust_2_-_Tiny_Reaction_Diffusion_Mix_-_bombay.milk",
    "Martin_-_QBikal_-_Surface_Turbulence_IIy2_by_hakanh_mash-up.milk",
    "Royal_-_Mashup_271.milk",
    "Royal_-_Mashup_372.milk",
    "Royal_-_Mashup_409.milk",
    "Stahlregen_fishbrain_Geiss_-_Witchcraft_Dense_-_painterly_oil_reflections_-_forcing_the_stars_rig2.milk",
    "Tripgnosis_-_Golden.milk",
    "Zylot_-_Paint_Spill_Music_Reactive_Paint_Mix_nz_nanobot_jag-gel_lord_s_piss.milk",
    "Zylot_Rovastar_-_Crystal_Ball_Cerimonial_Decor_Mix.milk",
    "amandio_c_-_interference_pattern_1.milk",
    "cleave_and_cleave_to_thine_w_thankee_sai_for_more_trippy_ass_shit_moneymaggot.milk",
    "eye_disease.milk",
    "fed_-_glowing_5_-_fingers_rmx_nz_ends_badly_fieldlessness_not_angel_day.milk",
    "flexi_-_splatter_effects_17_the_wave_a_google_love_story_written_in_decay_nz.milk",
    "hexagonal_water_ozone_air_grounded_to_earth_tranced_in_fire_prana_sourced_timbres_spher_absolute_meaning_i_don_t_know.milk",
    "lit_claw_explorers_grid_nz.milk",
    "martin_-_time_machine_sataniq_warp.milk",
    "martin_-_water_test_nz_the_pure_be_damned.milk",
    "phinjamain.milk",
    "red_and_white2_blowhorde_ws3_space_cuckoidth.milk",
    "repressed_americans_-_massive_cheese_lard_nz_slob_anti-gravity.milk",
    "repressed_americans_-_mess_roam.milk",
    "shifter_-_fuzzball_3d_glasses_false_auralary2_bundw_mbasthardische.milk",
    "shifter_Flexi_-_liquid_circuitry_from_the_neon_grafitti_hive_nz_whoever_fucked_with_my_nephew_s_life_gets_really_horrible_right_now.milk",
    "shifter_Flexi_-_liquid_circuitry_from_the_pataoblivion_hive_galactic_atomism_xfr_initiation_progression.milk",
    "suksma_-_antiinorganics_primal_dialectomy_-_silently_observed_pain_body_roam_proximately_bastardized.milk",
    "suksma_-_dumb_-_zhuGan.milk",
    "suksma_-_ed_geining_hateops_-_flx_everything_is_wishing_everything_is_spinning_roam.milk",
    "suksma_-_flexi_-_fractrip_-_lofted_guts_-_flacc_nz_sth.milk",
    "suksma_-_gaeomaentaec_-_log_smell_2_-_flesh.milk",
    "suksma_-_god_most_comp_shaders_look_pretty_nice_with_this_-_pitkanen_spher.milk",
    "suksma_-_hugs_for_the_evil_-_kurt_curtain.milk",
    "suksma_-_let_it_all_end.milk",
    "suksma_-_pus_on_my_cat_-_agro-christen_the_harvest_vessel.milk",
    "suksma_-_who_framed_roger_rabid.milk",
    "suksma_flexi_geiss_rovastar_roosta_demonld_shifter_-_dr_horicon_willn_t_ignore_dr_fuqduqwen.milk",
    "unmitigate_the_pointlessness.milk",
    "va_ultramix_-_423.milk",
    "yin_-_100_-_Through_the_ether_qansre_phevre_nz_if_love_is_so_important_maybe_we_should_show_it.milk",
};

constexpr const char *kKnownCrashingPresetFilenames[] = {
    "LuX_-_Heavy_Texture_Trip_1.milk",
};

constexpr const char *kStaticHeavyPresetFilenames[] = {
    "to_know_the_reason_i_am_trapped_is_my_own_weakness_and_fear_-_the_trap_is_the_trap_roam_nz_window_into_satan_s_muiff.milk",
    "martin_-_neon_space_ps2_ati_fix_-_yaqui_graph_-_flx_food_nz_deign_meant_you_knit_suspluded.milk",
    "rediculator_qrem_glob.milk",
    "f_wen_blew_my_wallet_-_how_to_beat_nothingness_into_omninmi-submission-potence.milk",
    "suksma_-_sun_pod_gambit_couch_-_flx_infinity_within_a_finite_boundary_---_Isosceles_edit4.milk",
    "flexi_-_grind_my_glitch_up_198.milk",
    "xtramartin_99.milk",
    "flexi_-_bouncing_balls_mindblob_terraforming_flx_roams_domikleasing_undergraeduhate.milk",
    "suksma_-_atypicasualt_shf_all_is_du_bliss_guil.milk",
    "flexi_-_grind_my_glitch_up_249.milk",
    "suksma_-_biotoxins_on_strings_-_quantizied_bacteria_line_alien_bioluminescent_intestine_flx_per_vtx_equ.milk",
    "my_dismal_dream_i_live_and_breath_i_realize_i_cannot_leave_nz_r_boing_boing.milk",
    "shadowharlequin_-_gracefull_sunshine_smiles.milk",
    "martin_-_mandelbox_explorer_v1_nz_laser_dome.milk",
    "EoS_-_Phat_-_randombox_-_mantra_5_response_lullquestent_vlasphume_fortitudinally_rhetroricidal_nz.milk",
    "390_threx_no_more_warningsce_metal_hellth_with_her_hand.milk",
    "shifter_-_dark_tides_bdrv_mix.milk",
    "GreatWho_-_Lasershow.milk",  // 818ms; missed by the sweep, caught live by the learned-slow guard 2026-07-04
};

template <size_t N>
void InsertAll(std::unordered_set<std::string> &set, const char *const (&values)[N])
{
    for (const char *value : values)
    {
        set.insert(value);
    }
}

void SkipWhitespace(std::string_view text, size_t &offset)
{
    while (offset < text.size() && std::isspace(static_cast<unsigned char>(text[offset])))
    {
        ++offset;
    }
}

bool Consume(std::string_view text, size_t &offset, char c)
{
    SkipWhitespace(text, offset);
    if (offset >= text.size() || text[offset] != c)
    {
        return false;
    }
    ++offset;
    return true;
}

bool ParseString(std::string_view text, size_t &offset, std::string &out)
{
    SkipWhitespace(text, offset);
    if (offset >= text.size() || text[offset] != '"')
    {
        return false;
    }
    ++offset;
    out.clear();
    while (offset < text.size())
    {
        char c = text[offset++];
        if (c == '"')
        {
            return true;
        }
        if (c == '\\')
        {
            if (offset >= text.size())
            {
                return false;
            }
            char escaped = text[offset++];
            switch (escaped)
            {
                case '"':
                case '\\':
                case '/':
                    out.push_back(escaped);
                    break;
                case 'b':
                    out.push_back('\b');
                    break;
                case 'f':
                    out.push_back('\f');
                    break;
                case 'n':
                    out.push_back('\n');
                    break;
                case 'r':
                    out.push_back('\r');
                    break;
                case 't':
                    out.push_back('\t');
                    break;
                default:
                    return false;
            }
        }
        else
        {
            out.push_back(c);
        }
    }
    return false;
}

bool ParseStringArray(std::string_view text, size_t &offset, std::unordered_set<std::string> &out)
{
    if (!Consume(text, offset, '['))
    {
        return false;
    }
    SkipWhitespace(text, offset);
    if (offset < text.size() && text[offset] == ']')
    {
        ++offset;
        return true;
    }

    while (offset < text.size())
    {
        std::string value;
        if (!ParseString(text, offset, value))
        {
            return false;
        }
        if (!value.empty())
        {
            out.insert(value);
        }

        SkipWhitespace(text, offset);
        if (offset < text.size() && text[offset] == ',')
        {
            ++offset;
            continue;
        }
        if (offset < text.size() && text[offset] == ']')
        {
            ++offset;
            return true;
        }
        return false;
    }
    return false;
}

}  // namespace

const PresetBlocklists &DefaultPresetBlocklists()
{
    static const PresetBlocklists blocklists = [] {
        PresetBlocklists lists;
        InsertAll(lists.slow, kKnownSlowPresetFilenames);
        InsertAll(lists.crashing, kKnownCrashingPresetFilenames);
        InsertAll(lists.staticHeavy, kStaticHeavyPresetFilenames);
        return lists;
    }();
    return blocklists;
}

bool ParsePresetBlocklistJSON(const char *bytes, size_t length, PresetBlocklists &out)
{
    out = PresetBlocklists();
    if (bytes == nullptr || length == 0)
    {
        return false;
    }

    std::string_view text(bytes, length);
    size_t offset = 0;
    bool sawSlow = false;
    bool sawCrashing = false;
    bool sawStaticHeavy = false;

    if (!Consume(text, offset, '{'))
    {
        return false;
    }
    SkipWhitespace(text, offset);
    if (offset < text.size() && text[offset] == '}')
    {
        return false;
    }

    while (offset < text.size())
    {
        std::string key;
        if (!ParseString(text, offset, key) || !Consume(text, offset, ':'))
        {
            return false;
        }

        if (key == "slow")
        {
            if (!ParseStringArray(text, offset, out.slow))
            {
                return false;
            }
            sawSlow = true;
        }
        else if (key == "crashing")
        {
            if (!ParseStringArray(text, offset, out.crashing))
            {
                return false;
            }
            sawCrashing = true;
        }
        else if (key == "staticHeavy")
        {
            if (!ParseStringArray(text, offset, out.staticHeavy))
            {
                return false;
            }
            sawStaticHeavy = true;
        }
        else
        {
            std::unordered_set<std::string> ignored;
            if (!ParseStringArray(text, offset, ignored))
            {
                return false;
            }
        }

        SkipWhitespace(text, offset);
        if (offset < text.size() && text[offset] == ',')
        {
            ++offset;
            continue;
        }
        if (offset < text.size() && text[offset] == '}')
        {
            ++offset;
            SkipWhitespace(text, offset);
            return offset == text.size() && sawSlow && sawCrashing && sawStaticHeavy;
        }
        return false;
    }
    return false;
}

bool IsSlowPreset(const PresetBlocklists &blocklists, const std::string &filename)
{
    return !filename.empty() && blocklists.slow.find(filename) != blocklists.slow.end();
}

bool IsCrashingPreset(const PresetBlocklists &blocklists, const std::string &filename)
{
    return !filename.empty() && blocklists.crashing.find(filename) != blocklists.crashing.end();
}

bool IsStaticHeavyPreset(const PresetBlocklists &blocklists, const std::string &filename)
{
    return !filename.empty() && blocklists.staticHeavy.find(filename) != blocklists.staticHeavy.end();
}

}  // namespace RoonVis
