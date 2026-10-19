// Model-backed regression check for the pinned decoder overlay. Not shipped in the app.
// Fixed codec inputs isolate chunk/state correctness from the talker's random sampling.
#include "common.h"
#include "llama.h"
#include "mtmd.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

struct Decoded { std::vector<float> pcm; std::vector<char> state; };

static double rms_error(const float * actual, const float * reference, size_t count) {
    double diff = 0, energy = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!std::isfinite(actual[i]) || !std::isfinite(reference[i])) throw std::runtime_error("nonfinite PCM/state");
        diff += std::pow(double(actual[i]) - reference[i], 2);
        energy += std::pow(double(reference[i]), 2);
    }
    return std::sqrt(diff / std::max(energy, 1e-20));
}

static Decoded decode(mtmd_context * ctx, int frames, int block) {
    std::vector<float> pcm;
    std::vector<char> state;
    for (int start = 0; start < frames; start += block) {
        const int count = std::min(block, frames - start);
        std::vector<int32_t> codes(count * 16);
        for (int f = 0; f < count; ++f)
            for (int g = 0; g < 16; ++g) codes[f * 16 + g] = ((start + f) * 31 + g * 17) % 1024;
        auto input = mtmd_gen_inp_default(ctx);
        input.type = MTMD_GEN_PROCESS_TYPE_GEN_WAV;
        input.codes = codes.data(); input.n_codes = codes.size();
        input.state_data = state.empty() ? nullptr : state.data(); input.state_size = state.size();
        mtmd_gen_out out{};
        if (mtmd_gen_audio_process(ctx, &input, &out) || !out.audio || !out.n_samples)
            throw std::runtime_error("decode failed");
        pcm.insert(pcm.end(), out.audio, out.audio + out.n_samples);
        state.assign(out.state_data, out.state_data + out.state_size);
    }
    return {std::move(pcm), std::move(state)};
}

int main(int argc, char ** argv) {
    if (argc != 3 && (argc != 4 || std::string(argv[3]) != "--cpu")) return 2;
    const bool cpu = argc == 4;
    try {
        common_init(); llama_backend_init();
        common_params params;
        params.model.path = argv[1]; params.n_gpu_layers = cpu ? 0 : 99;
        params.n_ctx = 4096; params.embedding = true; params.pooling_type = LLAMA_POOLING_TYPE_NONE;
        params.cpuparams.n_threads = 4; params.cpuparams_batch.n_threads = 4;
        auto loaded = common_init_from_params(params);
        auto options = mtmd_context_params_default(); options.use_gpu = !cpu;
        mtmd::context_ptr ctx(mtmd_init_from_file(argv[2], loaded->model(), options));
        if (!ctx) throw std::runtime_error("load failed");
        double worst = 0;
        int checks = 0;
        const std::vector<int> lengths = cpu ? std::vector<int>{8, 73} : std::vector<int>{1, 8, 71, 72, 73, 144, 145};
        const std::vector<int> blocks = cpu ? std::vector<int>{8} : std::vector<int>{4, 8, 16};
        for (int frames : lengths) {
            const auto reference = decode(ctx.get(), frames, 72);
            for (int block : blocks) {
                const auto actual = decode(ctx.get(), frames, block);
                if (actual.pcm.size() != reference.pcm.size() || actual.state.size() != reference.state.size())
                    throw std::runtime_error("sample/state count differs");
                const double error = rms_error(actual.pcm.data(), reference.pcm.data(), actual.pcm.size());
                const size_t prefix = reference.pcm.size() / frames * std::min(block, frames);
                const double first_error = rms_error(actual.pcm.data(), reference.pcm.data(), prefix);
                std::vector<float> state_a(actual.state.size() / 4), state_b(reference.state.size() / 4);
                std::memcpy(state_a.data(), actual.state.data(), actual.state.size());
                std::memcpy(state_b.data(), reference.state.data(), reference.state.size());
                const double state_error = rms_error(state_a.data(), state_b.data(), state_a.size());
                std::cerr << "frames=" << frames << " block=" << block << " relative_rms=" << error
                          << " first_block_rms=" << first_error << " state_rms=" << state_error << '\n';
                worst = std::max(worst, error);
                if (!cpu && error > 0.01) throw std::runtime_error("decoder continuity differs");
                ++checks;
            }
        }
        for (size_t count : {size_t(0), size_t(1), size_t(15), size_t(73 * 16)}) {
            std::vector<int32_t> codes(count, 1);
            auto input = mtmd_gen_inp_default(ctx.get());
            input.type = MTMD_GEN_PROCESS_TYPE_GEN_WAV;
            input.codes = codes.data(); input.n_codes = count;
            mtmd_gen_out out{};
            if (mtmd_gen_audio_process(ctx.get(), &input, &out) == 0) throw std::runtime_error("invalid input accepted");
            ++checks;
        }
        std::cout << "{\"backend\":\"" << (cpu ? "cpu" : "metal") << "\",\"diagnostic_only\":" << (cpu ? "true" : "false")
                  << ",\"checks\":" << checks
                  << ",\"worst_relative_rms_error\":" << worst << "}\n";
        return 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
