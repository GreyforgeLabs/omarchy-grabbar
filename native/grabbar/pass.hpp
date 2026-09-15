#pragma once

// Render pass element for the Grabbar strip. Structure follows Hyprbars'
// CBarPassElement (BSD-3-Clause, Hypr Development); see docs/UPSTREAM.md.

#include <hyprland/src/render/pass/PassElement.hpp>

class CGrabbarDeco;

class CGrabbarPassElement : public IPassElement {
  public:
    struct SBarData {
        CGrabbarDeco* deco = nullptr;
        float         a    = 1.F;
    };

    CGrabbarPassElement(const SBarData& data);
    virtual ~CGrabbarPassElement() = default;

    virtual std::vector<UP<IPassElement>> draw() override;
    virtual bool                          needsLiveBlur() override;
    virtual bool                          needsPrecomputeBlur() override;
    virtual std::optional<CBox>           boundingBox() override;

    virtual const char*                   passName() override {
        return "CGrabbarPassElement";
    }

    virtual ePassElementType type() override {
        return EK_CUSTOM;
    }

  private:
    SBarData m_data;
};
