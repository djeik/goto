package return_block

func plus(a, b int) int {
    {
        if true {
            if false {
                return 1
            } else {
                return 1
            }
        } else {
            return 0
        }
    }
}

func main() {
    plus(1,2)
}
