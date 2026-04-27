package com.reader.client.emv

data class Tlv(
    val tag: String,
    val length: Int,
    val value: String,
    val children: List<Tlv> = emptyList(),
) {
    fun getAid(): String? {
        if (tag == "4F") {
            return value
        }
        return children.mapNotNull { it.getAid() }.firstOrNull()
    }

    fun getLabel(): String? {
        if (tag == "50") {
            return hexToAscii(value)
        }
        return children.mapNotNull { it.getLabel() }.firstOrNull()
    }

    fun getPdol(): String? {
        if (tag.uppercase() == "9F38") {
            return value
        }
        return children.mapNotNull { it.getPdol() }.firstOrNull()
    }

    fun findTag(tagToFind: String): Tlv? {
        if (tag.uppercase() == tagToFind.uppercase()) {
            return this
        }
        for (child in children) {
            val found = child.findTag(tagToFind)
            if (found != null) {
                return found
            }
        }
        return null
    }

    private fun hexToAscii(hex: String): String {
        val output = StringBuilder()
        var i = 0
        while (i < hex.length) {
            output.append(hex.substring(i, i + 2).toInt(16).toChar())
            i += 2
        }
        return output.toString()
    }
}
