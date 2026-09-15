#include "pass.hpp"

#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>

#include "bar.hpp"

CGrabbarPassElement::CGrabbarPassElement(const CGrabbarPassElement::SBarData& data) : m_data(data) {
    ;
}

std::vector<UP<IPassElement>> CGrabbarPassElement::draw() {
    m_data.deco->renderPass(g_pHyprRenderer->m_renderData.pMonitor.lock(), m_data.a);
    return {};
}

bool CGrabbarPassElement::needsLiveBlur() {
    return false;
}

std::optional<CBox> CGrabbarPassElement::boundingBox() {
    // Expand a little so occlusion culling does not clip the strip's rounded corners.
    return m_data.deco->assignedBoxGlobal().translate(-g_pHyprRenderer->m_renderData.pMonitor->m_position).expand(10);
}

bool CGrabbarPassElement::needsPrecomputeBlur() {
    return false;
}
